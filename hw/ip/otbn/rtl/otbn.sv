// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`include "prim_assert.sv"

/**
 * OpenTitan Big Number Accelerator (OTBN)
 */
module otbn
  import prim_alert_pkg::*;
  import otbn_pkg::*;
  import otbn_reg_pkg::*;
#(
  parameter bit                   Stub         = 1'b0,
  parameter regfile_e             RegFile      = RegFileFF,
  parameter logic [NumAlerts-1:0] AlertAsyncOn = {NumAlerts{1'b1}},

  // Default seed and permutation for URND LFSR
  parameter urnd_lfsr_seed_t       RndCnstUrndLfsrSeed      = RndCnstUrndLfsrSeedDefault,
  parameter urnd_chunk_lfsr_perm_t RndCnstUrndChunkLfsrPerm = RndCnstUrndChunkLfsrPermDefault,

  // Default seed and nonce for scrambling
  parameter otp_ctrl_pkg::otbn_key_t   RndCnstOtbnKey   = RndCnstOtbnKeyDefault,
  parameter otp_ctrl_pkg::otbn_nonce_t RndCnstOtbnNonce = RndCnstOtbnNonceDefault
) (
  input clk_i,
  input rst_ni,

  input  tlul_pkg::tl_h2d_t tl_i,
  output tlul_pkg::tl_d2h_t tl_o,

  // Inter-module signals
  output logic idle_o,
  output logic idle_otp_o,

  // Interrupts
  output logic intr_done_o,

  // Alerts
  input  prim_alert_pkg::alert_rx_t [NumAlerts-1:0] alert_rx_i,
  output prim_alert_pkg::alert_tx_t [NumAlerts-1:0] alert_tx_o,

  // Lifecycle interface
  input lc_ctrl_pkg::lc_tx_t lc_escalate_en_i,

  // Memory configuration
  input prim_ram_1p_pkg::ram_1p_cfg_t ram_cfg_i,

  // EDN clock and interface
  input                                              clk_edn_i,
  input                                              rst_edn_ni,
  output edn_pkg::edn_req_t                          edn_rnd_o,
  input  edn_pkg::edn_rsp_t                          edn_rnd_i,

  output edn_pkg::edn_req_t                          edn_urnd_o,
  input  edn_pkg::edn_rsp_t                          edn_urnd_i,

  // Key request to OTP (running on clk_fixed)
  input                                              clk_otp_i,
  input                                              rst_otp_ni,
  output otp_ctrl_pkg::otbn_otp_key_req_t            otbn_otp_key_o,
  input  otp_ctrl_pkg::otbn_otp_key_rsp_t            otbn_otp_key_i
);

  import prim_util_pkg::vbits;

  logic rst_n;

  // hold module in reset permanently when stubbing
  if (Stub) begin : gen_stub_otbn
    assign rst_n = 1'b0;
  end else begin : gen_real_otbn
    assign rst_n = rst_ni;
  end

  // The OTBN_*_SIZE parameters are auto-generated by regtool and come from the
  // bus window sizes; they are given in bytes and must be powers of two.
  localparam int ImemSizeByte = int'(otbn_reg_pkg::OTBN_IMEM_SIZE);
  localparam int DmemSizeByte = int'(otbn_reg_pkg::OTBN_DMEM_SIZE);

  localparam int ImemAddrWidth = vbits(ImemSizeByte);
  localparam int DmemAddrWidth = vbits(DmemSizeByte);

  `ASSERT_INIT(ImemSizePowerOfTwo, 2**ImemAddrWidth == ImemSizeByte)
  `ASSERT_INIT(DmemSizePowerOfTwo, 2**DmemAddrWidth == DmemSizeByte)

  logic start_d, start_q;
  logic busy_execute_d, busy_execute_q;
  logic done;
  logic locked;
  logic illegal_bus_access_d, illegal_bus_access_q;

  err_bits_t err_bits;

  logic software_errs_fatal_q, software_errs_fatal_d;

  otbn_reg2hw_t reg2hw;
  otbn_hw2reg_t hw2reg;

  // Bus device windows, as specified in otbn.hjson
  typedef enum logic {
    TlWinImem = 1'b0,
    TlWinDmem = 1'b1
  } tl_win_e;

  tlul_pkg::tl_h2d_t tl_win_h2d [2];
  tlul_pkg::tl_d2h_t tl_win_d2h [2];


  // Inter-module signals ======================================================

  // TODO: Use STATUS == IDLE here.
  assign idle_o = ~busy_execute_q;

  // TODO: These two signals aren't technically in the same clock domain. Sort out how we do the
  // signalling properly.
  assign idle_otp_o = idle_o;

  // Lifecycle ==================================================================

  lc_ctrl_pkg::lc_tx_t lc_escalate_en;
  prim_lc_sync #(
    .NumCopies(1)
  ) u_lc_escalate_en_sync (
    .clk_i,
    .rst_ni,
    .lc_en_i(lc_escalate_en_i),
    .lc_en_o(lc_escalate_en)
  );

  // Reduce the life cycle escalation signal to a single bit to be used within this cycle.
  logic lifecycle_escalation;
  assign lifecycle_escalation = lc_escalate_en != lc_ctrl_pkg::Off;

  // Interrupts ================================================================

  prim_intr_hw #(
    .Width(1)
  ) u_intr_hw_done (
    .clk_i,
    .rst_ni                 (rst_n),
    .event_intr_i           (done),
    .reg2hw_intr_enable_q_i (reg2hw.intr_enable.q),
    .reg2hw_intr_test_q_i   (reg2hw.intr_test.q),
    .reg2hw_intr_test_qe_i  (reg2hw.intr_test.qe),
    .reg2hw_intr_state_q_i  (reg2hw.intr_state.q),
    .hw2reg_intr_state_de_o (hw2reg.intr_state.de),
    .hw2reg_intr_state_d_o  (hw2reg.intr_state.d),
    .intr_o                 (intr_done_o)
  );

  // Instruction Memory (IMEM) =================================================

  localparam int ImemSizeWords = ImemSizeByte / 4;
  localparam int ImemIndexWidth = vbits(ImemSizeWords);

  // Access select to IMEM: core (1), or bus (0)
  logic imem_access_core;

  logic imem_req;
  logic imem_write;
  logic [ImemIndexWidth-1:0] imem_index;
  logic [38:0] imem_wdata;
  logic [38:0] imem_wmask;
  logic [38:0] imem_rdata;
  logic imem_rvalid;
  logic [1:0] imem_rerror_vec;
  logic imem_rerror;
  logic imem_illegal_bus_access;

  logic imem_req_core;
  logic imem_write_core;
  logic [ImemIndexWidth-1:0] imem_index_core;
  logic [31:0] imem_wdata_core;
  logic [31:0] imem_rdata_core;
  logic imem_rvalid_core;
  logic imem_rerror_core;

  logic imem_req_bus;
  logic imem_dummy_response_q, imem_dummy_response_d;
  logic imem_write_bus;
  logic [ImemIndexWidth-1:0] imem_index_bus;
  logic [38:0] imem_wdata_bus;
  logic [38:0] imem_wmask_bus;
  logic [38:0] imem_rdata_bus;
  logic imem_rvalid_bus;
  logic [1:0] imem_rerror_bus;

  logic imem_bus_intg_violation;

  logic [ImemAddrWidth-1:0] imem_addr_core;
  assign imem_index_core = imem_addr_core[ImemAddrWidth-1:2];

  logic [1:0] unused_imem_addr_core_wordbits;
  assign unused_imem_addr_core_wordbits = imem_addr_core[1:0];

  otp_ctrl_pkg::otbn_key_t otbn_imem_scramble_key;
  otbn_imem_nonce_t        otbn_imem_scramble_nonce;
  logic                    otbn_imem_scramble_valid;
  logic                    unused_otbn_imem_scramble_key_seed_valid;

  otp_ctrl_pkg::otbn_key_t otbn_dmem_scramble_key;
  otbn_dmem_nonce_t        otbn_dmem_scramble_nonce;
  logic                    otbn_dmem_scramble_valid;
  logic                    unused_otbn_dmem_scramble_key_seed_valid;

  otbn_scramble_ctrl #(
    .RndCnstOtbnKey   (RndCnstOtbnKey),
    .RndCnstOtbnNonce (RndCnstOtbnNonce)
  ) u_otbn_scramble_ctrl (
    .clk_i,
    .rst_ni,

    .clk_otp_i,
    .rst_otp_ni,

    .otbn_otp_key_o,
    .otbn_otp_key_i,

    .otbn_dmem_scramble_key_o            (otbn_dmem_scramble_key           ),
    .otbn_dmem_scramble_nonce_o          (otbn_dmem_scramble_nonce         ),
    .otbn_dmem_scramble_valid_o          (otbn_dmem_scramble_valid         ),
    .otbn_dmem_scramble_key_seed_valid_o (unused_otbn_dmem_scramble_key_seed_valid),

    .otbn_imem_scramble_key_o            (otbn_imem_scramble_key           ),
    .otbn_imem_scramble_nonce_o          (otbn_imem_scramble_nonce         ),
    .otbn_imem_scramble_valid_o          (otbn_imem_scramble_valid         ),
    .otbn_imem_scramble_key_seed_valid_o (unused_otbn_imem_scramble_key_seed_valid),

    .otbn_dmem_scramble_new_req_i (1'b0),
    .otbn_imem_scramble_new_req_i (1'b0)
  );

  prim_ram_1p_scr #(
    .Width           (39),
    .Depth           (ImemSizeWords),
    .DataBitsPerMask (39),
    .EnableParity    (0),
    .DiffWidth       (39)
  ) u_imem (
    .clk_i,
    .rst_ni      (rst_n),

    .key_valid_i (otbn_imem_scramble_valid),
    .key_i       (otbn_imem_scramble_key),
    .nonce_i     (otbn_imem_scramble_nonce),

    .req_i       (imem_req),
    // TODO: Deal with grant signal, can we safely ignore?  Does OTBN need refactoring to deal with
    // no grant? If exposed to Ibex will result in long stall if there's no valid key, may not be
    // the behaviour we want, read error instead?
    .gnt_o       (),
    .write_i     (imem_write),
    .addr_i      (imem_index),
    .wdata_i     (imem_wdata),
    .wmask_i     (imem_wmask),
    .intg_error_i(1'b0),

    .rdata_o     (imem_rdata),
    .rvalid_o    (imem_rvalid),
    .raddr_o     (),
    .rerror_o    (),
    .cfg_i       (ram_cfg_i)
  );

  // Separate check for imem read data integrity outside of `u_imem` as `prim_ram_1p_adv` doesn't
  // have functionality for only integrity checking, just fully integrated ECC.
  prim_secded_39_32_dec u_imem_intg_check (
    .data_i     (imem_rdata),
    .data_o     (),
    .syndrome_o (),
    .err_o      (imem_rerror_vec)
  );

  // imem_rerror is only reported for reads from OTBN. For Ibex reads integrity checking on TL
  // responses will serve the same purpose.
  // imem_rerror_vec is 2 bits wide and is used to report ECC errors. Bit 1 is set if there's an
  // uncorrectable error and bit 0 is set if there's a correctable error. However, we're treating
  // all errors as fatal, so OR the two signals together.
  assign imem_rerror = |imem_rerror_vec & imem_rvalid & imem_access_core;

  // IMEM access from main TL-UL bus
  logic imem_gnt_bus;
  // Always grant to bus accesses, when OTBN is running a dummy response is returned
  assign imem_gnt_bus = imem_req_bus;

  import prim_mubi_pkg::MuBi4False;
  tlul_adapter_sram #(
    .SramAw      (ImemIndexWidth),
    .SramDw      (32),
    .Outstanding (1),
    .ByteAccess  (0),
    .ErrOnRead   (0),
    .EnableDataIntgPt (1)
  ) u_tlul_adapter_sram_imem (
    .clk_i,
    .rst_ni      (rst_n                  ),
    .tl_i        (tl_win_h2d[TlWinImem]  ),
    .tl_o        (tl_win_d2h[TlWinImem]  ),
    .en_ifetch_i (MuBi4False             ),
    .req_o       (imem_req_bus           ),
    .req_type_o  (                       ),
    .gnt_i       (imem_gnt_bus           ),
    .we_o        (imem_write_bus         ),
    .addr_o      (imem_index_bus         ),
    .wdata_o     (imem_wdata_bus         ),
    .wmask_o     (imem_wmask_bus         ),
    .intg_error_o(imem_bus_intg_violation),
    .rdata_i     (imem_rdata_bus         ),
    .rvalid_i    (imem_rvalid_bus        ),
    .rerror_i    (imem_rerror_bus        )
  );


  // Mux core and bus access into IMEM
  assign imem_access_core = busy_execute_q | start_q;

  assign imem_req   = imem_access_core ? imem_req_core        : imem_req_bus;
  assign imem_write = imem_access_core ? imem_write_core      : imem_write_bus;
  assign imem_index = imem_access_core ? imem_index_core      : imem_index_bus;
  assign imem_wdata = imem_access_core ? 39'(imem_wdata_core) : imem_wdata_bus;

  assign imem_illegal_bus_access = imem_req_bus & imem_access_core;

  assign imem_dummy_response_d = imem_illegal_bus_access;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      imem_dummy_response_q <= 1'b0;
    end else begin
      imem_dummy_response_q <= imem_dummy_response_d;
    end
  end

  // The instruction memory only supports 32b word writes, so we hardcode its
  // wmask here.
  //
  // Since this could cause confusion if the bus tried to do a partial write
  // (which wasn't caught in the TLUL adapter for some reason), we assert that
  // the wmask signal from the bus is indeed '1 when it requests a write. We
  // don't have the corresponding check for writes from the core because the
  // core cannot perform writes (and has no imem_wmask_o port).
  assign imem_wmask = imem_access_core ? '1 : imem_wmask_bus;
  `ASSERT(ImemWmaskBusIsFullWord_A,
      imem_req_bus && imem_write_bus |-> imem_wmask_bus == '1)

  // Explicitly tie off bus interface during core operation to avoid leaking
  // the currently executed instruction from IMEM through the bus
  // unintentionally.
  assign imem_rdata_bus  = !imem_access_core && !illegal_bus_access_q ? imem_rdata : 39'b0;
  assign imem_rdata_core = imem_rdata[31:0];

  // When an illegal bus access is seen, always return a dummy response the follow cycle.
  assign imem_rvalid_bus  = (~imem_access_core & imem_rvalid) | imem_dummy_response_q;
  assign imem_rvalid_core = imem_access_core ? imem_rvalid : 1'b0;

  // imem_rerror_bus is passed to a TLUL adapter to report read errors back to the TL interface.
  // We've squashed together the 2 bits from ECC into a single (uncorrectable) error, but the TLUL
  // adapter expects the original ECC format. Send imem_rerror as bit 1, signalling an
  // uncorrectable error.
  //
  // The mux ensures that imem_rerror doesn't appear on the bus (possibly leaking information) when
  // the core is operating. Since rerror depends on rvalid, we could avoid this mux. However that
  // seems a bit fragile, so we err on the side of caution.
  assign imem_rerror_bus  = !imem_access_core ? {imem_rerror, 1'b0} : 2'b00;
  assign imem_rerror_core = imem_rerror;

  // Data Memory (DMEM) ========================================================

  localparam int DmemSizeWords = DmemSizeByte / (WLEN / 8);
  localparam int DmemIndexWidth = vbits(DmemSizeWords);

  // Access select to DMEM: core (1), or bus (0)
  logic dmem_access_core;

  logic dmem_req;
  logic dmem_write;
  logic [DmemIndexWidth-1:0] dmem_index;
  logic [ExtWLEN-1:0] dmem_wdata;
  logic [ExtWLEN-1:0] dmem_wmask;
  logic [ExtWLEN-1:0] dmem_rdata;
  logic dmem_rvalid;
  logic [BaseWordsPerWLEN*2-1:0] dmem_rerror_vec;
  logic dmem_rerror;
  logic dmem_illegal_bus_access;

  logic dmem_req_core;
  logic dmem_write_core;
  logic [DmemIndexWidth-1:0] dmem_index_core;
  logic [ExtWLEN-1:0] dmem_wdata_core;
  logic [ExtWLEN-1:0] dmem_wmask_core;
  logic [BaseWordsPerWLEN-1:0] dmem_rmask_core_q, dmem_rmask_core_d;
  logic [ExtWLEN-1:0] dmem_rdata_core;
  logic dmem_rvalid_core;
  logic dmem_rerror_core;

  logic dmem_req_bus;
  logic dmem_dummy_response_q, dmem_dummy_response_d;
  logic dmem_write_bus;
  logic [DmemIndexWidth-1:0] dmem_index_bus;
  logic [ExtWLEN-1:0] dmem_wdata_bus;
  logic [ExtWLEN-1:0] dmem_wmask_bus;
  logic [ExtWLEN-1:0] dmem_rdata_bus;
  logic dmem_rvalid_bus;
  logic [1:0] dmem_rerror_bus;

  logic dmem_bus_intg_violation;

  logic [DmemAddrWidth-1:0] dmem_addr_core;
  assign dmem_index_core = dmem_addr_core[DmemAddrWidth-1:DmemAddrWidth-DmemIndexWidth];

  logic unused_dmem_addr_core_wordbits;
  assign unused_dmem_addr_core_wordbits = ^dmem_addr_core[DmemAddrWidth-DmemIndexWidth-1:0];

  prim_ram_1p_scr #(
    .Width              (ExtWLEN),
    .Depth              (DmemSizeWords),
    .DataBitsPerMask    (39),
    .EnableParity       (0),
    .DiffWidth          (39),
    .ReplicateKeyStream (1)
  ) u_dmem (
    .clk_i,
    .rst_ni      (rst_n),

    .key_valid_i (otbn_dmem_scramble_valid),
    .key_i       (otbn_dmem_scramble_key),
    .nonce_i     (otbn_dmem_scramble_nonce),

    .req_i       (dmem_req),
    // TODO: Deal with grant signal, can we safely ignore?  Does OTBN need refactoring to deal with
    // no grant? If exposed to Ibex will result in long stall if there's no valid key, may not be
    // the behaviour we want, read error instead?
    .gnt_o       (),
    .write_i     (dmem_write),
    .addr_i      (dmem_index),
    .wdata_i     (dmem_wdata),
    .wmask_i     (dmem_wmask),
    .intg_error_i(1'b0),

    .rdata_o     (dmem_rdata),
    .rvalid_o    (dmem_rvalid),
    .raddr_o     (),
    .rerror_o    (),
    .cfg_i       (ram_cfg_i)
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      dmem_rmask_core_q <= '0;
    end else begin
      if (dmem_req_core) begin
        dmem_rmask_core_q <= dmem_rmask_core_d;
      end
    end
  end

  for (genvar i_word = 0; i_word < BaseWordsPerWLEN; ++i_word) begin : g_dmem_intg_check
    logic [1:0] dmem_rerror_raw;

    // Separate check for dmem read data integrity outside of `u_dmem` as `prim_ram_1p_adv` doesn't
    // have functionality for only integrity checking, just fully integrated ECC. Integrity bits are
    // implemented on a 32-bit granule so separate checks are required for each.
    prim_secded_39_32_dec u_dmem_intg_check (
      .data_i     (dmem_rdata[i_word*39 +: 39]),
      .data_o     (),
      .syndrome_o (),
      .err_o      (dmem_rerror_raw)
    );

    // Only report an error where the word was actually accessed. Otherwise uninitialised memory
    // that OTBN isn't using will cause false errors. dmem_rerror is only reported for reads from
    // OTBN. For Ibex reads integrity checking on TL responses will serve the same purpose.
    assign dmem_rerror_vec[i_word*2 +: 2] = dmem_rerror_raw &
        {2{dmem_rmask_core_q[i_word] & dmem_rvalid & dmem_access_core}};
  end

  // Combine uncorrectable / correctable errors. See note above definition of imem_rerror for
  // details.
  assign dmem_rerror = |dmem_rerror_vec;

  // DMEM access from main TL-UL bus
  logic dmem_gnt_bus;
  // Always grant to bus accesses, when OTBN is running a dummy response is returned
  assign dmem_gnt_bus = dmem_req_bus;

  tlul_adapter_sram #(
    .SramAw      (DmemIndexWidth),
    .SramDw      (WLEN),
    .Outstanding (1),
    .ByteAccess  (0),
    .ErrOnRead   (0),
    .EnableDataIntgPt (1)
  ) u_tlul_adapter_sram_dmem (
    .clk_i,
    .rst_ni      (rst_n                  ),
    .tl_i        (tl_win_h2d[TlWinDmem]  ),
    .tl_o        (tl_win_d2h[TlWinDmem]  ),
    .en_ifetch_i (MuBi4False             ),
    .req_o       (dmem_req_bus           ),
    .req_type_o  (                       ),
    .gnt_i       (dmem_gnt_bus           ),
    .we_o        (dmem_write_bus         ),
    .addr_o      (dmem_index_bus         ),
    .wdata_o     (dmem_wdata_bus         ),
    .wmask_o     (dmem_wmask_bus         ),
    .intg_error_o(dmem_bus_intg_violation),
    .rdata_i     (dmem_rdata_bus         ),
    .rvalid_i    (dmem_rvalid_bus        ),
    .rerror_i    (dmem_rerror_bus        )
  );

  // Mux core and bus access into dmem
  assign dmem_access_core = busy_execute_q;

  assign dmem_req   = dmem_access_core ? dmem_req_core   : dmem_req_bus;
  assign dmem_write = dmem_access_core ? dmem_write_core : dmem_write_bus;
  assign dmem_wmask = dmem_access_core ? dmem_wmask_core : dmem_wmask_bus;
  assign dmem_index = dmem_access_core ? dmem_index_core : dmem_index_bus;
  assign dmem_wdata = dmem_access_core ? dmem_wdata_core : dmem_wdata_bus;

  assign dmem_illegal_bus_access = dmem_req_bus & dmem_access_core;

  assign dmem_dummy_response_d = dmem_illegal_bus_access;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      dmem_dummy_response_q <= 1'b0;
    end else begin
      dmem_dummy_response_q <= dmem_dummy_response_d;
    end
  end

  // Explicitly tie off bus interface during core operation to avoid leaking
  // DMEM data through the bus unintentionally. Once an illegal bus access is seen always return
  // 0 data.
  assign dmem_rdata_bus  = !dmem_access_core && !illegal_bus_access_q ? dmem_rdata : '0;
  assign dmem_rdata_core = dmem_rdata;

  // When an illegal bus access is seen, always return a dummy response the follow cycle.
  assign dmem_rvalid_bus  = (~dmem_access_core & dmem_rvalid) | dmem_dummy_response_q;
  assign dmem_rvalid_core = dmem_access_core ? dmem_rvalid : 1'b0;

  // Expand the error signal to 2 bits and mask when the core has access. See note above
  // imem_rerror_bus for details.
  assign dmem_rerror_bus  = !dmem_access_core ? {dmem_rerror, 1'b0} : 2'b00;
  assign dmem_rerror_core = dmem_rerror;

  // Registers =================================================================

  logic reg_bus_intg_violation;

  otbn_reg_top u_reg (
    .clk_i,
    .rst_ni (rst_n),
    .tl_i,
    .tl_o,
    .tl_win_o (tl_win_h2d),
    .tl_win_i (tl_win_d2h),

    .reg2hw,
    .hw2reg,

    .intg_err_o(reg_bus_intg_violation),
    .devmode_i (1'b1)
  );

  logic bus_intg_violation;
  assign bus_intg_violation = (imem_bus_intg_violation | dmem_bus_intg_violation |
                               reg_bus_intg_violation);

  // CMD register
  // start is flopped to avoid long timing paths from the TL fabric into OTBN internals.
  assign start_d = reg2hw.cmd.qe & (reg2hw.cmd.q == CmdExecute);
  assign illegal_bus_access_d = dmem_illegal_bus_access | imem_illegal_bus_access;

  // Flop `illegal_bus_access_q` so we know an illegal bus access has happened and to break a timing
  // path from the TL interface into the OTBN core.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      start_q              <= 1'b0;
      illegal_bus_access_q <= 1'b0;
    end else begin
      start_q              <= start_d;
      illegal_bus_access_q <= illegal_bus_access_d;
    end
  end

  // STATUS register
  always_comb begin
    unique case (1'b1)
      busy_execute_q: hw2reg.status.d = StatusBusyExecute;
      locked:         hw2reg.status.d = StatusLocked;
      // TODO: Add other busy flags, and assert onehot encoding.
      default:        hw2reg.status.d = StatusIdle;
    endcase
  end
  assign hw2reg.status.de = 1'b1;

  `ASSERT(OtbnStatesOneHot, $onehot0({busy_execute_q, locked}))

  // CTRL register
  assign software_errs_fatal_d =
    reg2hw.ctrl.qe && (hw2reg.status.d == StatusIdle) ? reg2hw.ctrl.q :
                                                        software_errs_fatal_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      software_errs_fatal_q <= 1'b0;
    end else begin
      software_errs_fatal_q <= software_errs_fatal_d;
    end
  end

  assign hw2reg.ctrl.d = software_errs_fatal_q;

  // ERR_BITS register
  // The error bits for an OTBN operation get stored on the cycle that done is
  // asserted. Software is expected to read them out before starting the next operation.
  assign hw2reg.err_bits.bad_data_addr.de = done;
  assign hw2reg.err_bits.bad_data_addr.d = err_bits.bad_data_addr;

  assign hw2reg.err_bits.bad_insn_addr.de = done;
  assign hw2reg.err_bits.bad_insn_addr.d = err_bits.bad_insn_addr;

  assign hw2reg.err_bits.call_stack.de = done;
  assign hw2reg.err_bits.call_stack.d = err_bits.call_stack;

  assign hw2reg.err_bits.illegal_insn.de = done;
  assign hw2reg.err_bits.illegal_insn.d = err_bits.illegal_insn;

  assign hw2reg.err_bits.loop.de = done;
  assign hw2reg.err_bits.loop.d = err_bits.loop;

  assign hw2reg.err_bits.imem_intg_violation.de = done;
  assign hw2reg.err_bits.imem_intg_violation.d = err_bits.imem_intg_violation;

  assign hw2reg.err_bits.dmem_intg_violation.de = done;
  assign hw2reg.err_bits.dmem_intg_violation.d = err_bits.dmem_intg_violation;

  assign hw2reg.err_bits.reg_intg_violation.de = done;
  assign hw2reg.err_bits.reg_intg_violation.d = err_bits.reg_intg_violation;

  assign hw2reg.err_bits.bus_intg_violation.de = done;
  assign hw2reg.err_bits.bus_intg_violation.d = err_bits.bus_intg_violation;

  assign hw2reg.err_bits.illegal_bus_access.de = done;
  assign hw2reg.err_bits.illegal_bus_access.d = err_bits.illegal_bus_access;

  assign hw2reg.err_bits.lifecycle_escalation.de = done;
  assign hw2reg.err_bits.lifecycle_escalation.d = err_bits.lifecycle_escalation;

  assign hw2reg.err_bits.fatal_software.de = done;
  assign hw2reg.err_bits.fatal_software.d = err_bits.fatal_software;

  // FATAL_ALERT_CAUSE register. The .de and .d values are equal for each bit, so that it can only
  // be set, not cleared.
  assign hw2reg.fatal_alert_cause.imem_intg_violation.de = imem_rerror;
  assign hw2reg.fatal_alert_cause.imem_intg_violation.d  = imem_rerror;
  assign hw2reg.fatal_alert_cause.dmem_intg_violation.de = dmem_rerror;
  assign hw2reg.fatal_alert_cause.dmem_intg_violation.d  = dmem_rerror;
  // TODO: Register file errors
  assign hw2reg.fatal_alert_cause.reg_intg_violation.de = 0;
  assign hw2reg.fatal_alert_cause.reg_intg_violation.d  = 0;
  assign hw2reg.fatal_alert_cause.bus_intg_violation.de = bus_intg_violation;
  assign hw2reg.fatal_alert_cause.bus_intg_violation.d  = bus_intg_violation;
  assign hw2reg.fatal_alert_cause.illegal_bus_access.de = illegal_bus_access_d;
  assign hw2reg.fatal_alert_cause.illegal_bus_access.d  = illegal_bus_access_d;
  assign hw2reg.fatal_alert_cause.lifecycle_escalation.de = lifecycle_escalation;
  assign hw2reg.fatal_alert_cause.lifecycle_escalation.d  = lifecycle_escalation;
  assign hw2reg.fatal_alert_cause.fatal_software.de = done;
  assign hw2reg.fatal_alert_cause.fatal_software.d  = err_bits.fatal_software;

  // INSN_CNT register
  logic [31:0] insn_cnt;
  assign hw2reg.insn_cnt.d = insn_cnt;

  // Alerts ====================================================================

  logic [NumAlerts-1:0] alert_test;
  assign alert_test[AlertFatal] = reg2hw.alert_test.fatal.q &
                                  reg2hw.alert_test.fatal.qe;
  assign alert_test[AlertRecov] = reg2hw.alert_test.recov.q &
                                  reg2hw.alert_test.recov.qe;

  logic [NumAlerts-1:0] alerts;
  assign alerts[AlertFatal] = imem_rerror          |
                              dmem_rerror          |
                              bus_intg_violation   |
                              illegal_bus_access_d |
                              lifecycle_escalation |
                              err_bits.fatal_software;

  assign alerts[AlertRecov] = 1'b0; // TODO: Implement

  for (genvar i = 0; i < NumAlerts; i++) begin: gen_alert_tx
    prim_alert_sender #(
      .AsyncOn(AlertAsyncOn[i]),
      .IsFatal(i == AlertFatal)
    ) u_prim_alert_sender (
      .clk_i,
      .rst_ni        ( rst_n         ),
      .alert_test_i  ( alert_test[i] ),
      .alert_req_i   ( alerts[i]     ),
      .alert_ack_o   (               ),
      .alert_state_o (               ),
      .alert_rx_i    ( alert_rx_i[i] ),
      .alert_tx_o    ( alert_tx_o[i] )
    );
  end


  // EDN Connections ============================================================
  logic edn_rnd_req, edn_rnd_ack;
  logic [EdnDataWidth-1:0] edn_rnd_data;

  logic edn_urnd_req, edn_urnd_ack;
  logic [EdnDataWidth-1:0] edn_urnd_data;

  // These synchronize the data coming from EDN and stack the 32 bit EDN words to achieve an
  // internal entropy width of 256 bit.

  prim_edn_req #(
    .OutWidth(EdnDataWidth)
  ) u_prim_edn_rnd_req (
    .clk_i,
    .rst_ni     ( rst_n        ),
    .req_chk_i  ( 1'b1         ),
    .req_i      ( edn_rnd_req  ),
    .ack_o      ( edn_rnd_ack  ),
    .data_o     ( edn_rnd_data ),
    .fips_o     (              ), // unused
    .clk_edn_i,
    .rst_edn_ni,
    .edn_o      ( edn_rnd_o    ),
    .edn_i      ( edn_rnd_i    )
  );

  prim_edn_req #(
    .OutWidth(EdnDataWidth)
  ) u_prim_edn_urnd_req (
    .clk_i,
    .rst_ni     ( rst_n         ),
    .req_chk_i  ( 1'b1          ),
    .req_i      ( edn_urnd_req  ),
    .ack_o      ( edn_urnd_ack  ),
    .data_o     ( edn_urnd_data ),
    .fips_o     (               ), // unused
    .clk_edn_i,
    .rst_edn_ni,
    .edn_o      ( edn_urnd_o    ),
    .edn_i      ( edn_urnd_i    )
  );


  // OTBN Core =================================================================

  always_ff @(posedge clk_i or negedge rst_n) begin
    if (!rst_n) begin
      busy_execute_q <= 1'b0;
    end else begin
      busy_execute_q <= busy_execute_d;
    end
  end
  assign busy_execute_d = (busy_execute_q | start_d) & ~done;

  `ifdef OTBN_BUILD_MODEL
    // Build both model and RTL implementation into the design, and switch at runtime through a
    // plusarg.

    // Set the plusarg +OTBN_USE_MODEL=1 to use the model (ISS) instead of the RTL implementation.
    bit otbn_use_model;
    initial begin
      $value$plusargs("OTBN_USE_MODEL=%d", otbn_use_model);
    end

    // Mux between model and RTL implementation at runtime.
    logic         done_rr_model, done_rtl;
    logic         locked_model, locked_rtl;
    logic         start_model, start_rtl;
    err_bits_t    err_bits_model, err_bits_rtl;
    logic [31:0]  insn_cnt_model, insn_cnt_rtl;
    logic         edn_rnd_data_valid;
    logic         edn_urnd_data_valid;

    // Note that the "done" signal will come two cycles later when using the model as a core than it
    // does when using the RTL
    assign done = otbn_use_model ? done_rr_model : done_rtl;
    assign locked = otbn_use_model ? locked_model : locked_rtl;
    assign err_bits = otbn_use_model ? err_bits_model : err_bits_rtl;
    assign insn_cnt = otbn_use_model ? insn_cnt_model : insn_cnt_rtl;
    assign start_model = start_q & otbn_use_model;
    assign start_rtl = start_q & ~otbn_use_model;

    // Model (Instruction Set Simulator)
    assign edn_rnd_data_valid = edn_rnd_req & edn_rnd_ack;
    assign edn_urnd_data_valid = otbn_use_model ? 1'b1 : edn_urnd_req & edn_urnd_ack;

    otbn_core_model #(
      .DmemSizeByte(DmemSizeByte),
      .ImemSizeByte(ImemSizeByte),
      .MemScope(".."),
      .DesignScope("")
    ) u_otbn_core_model (
      .clk_i,
      .clk_edn_i,

      .rst_ni                (rst_n),
      .rst_edn_ni,

      .start_i               (start_model),

      .err_bits_o            (err_bits_model),

      .edn_rnd_i             (edn_rnd_i),
      .edn_rnd_cdc_done_i    (edn_rnd_data_valid),

      .edn_urnd_data_valid_i (edn_urnd_data_valid),

      .insn_cnt_o            (insn_cnt_model),

      .done_rr_o (done_rr_model),

      .err_o ()
    );

    assign locked_model = 1'b0;

    // RTL implementation
    otbn_core #(
      .RegFile(RegFile),
      .DmemSizeByte(DmemSizeByte),
      .ImemSizeByte(ImemSizeByte),
      .RndCnstUrndLfsrSeed(RndCnstUrndLfsrSeed),
      .RndCnstUrndChunkLfsrPerm(RndCnstUrndChunkLfsrPerm)
    ) u_otbn_core (
      .clk_i,
      .rst_ni                 (rst_n),

      .start_i                (start_rtl),
      .done_o                 (done_rtl),
      .locked_o               (locked_rtl),

      .err_bits_o             (err_bits_rtl),

      .imem_req_o             (imem_req_core),
      .imem_addr_o            (imem_addr_core),
      .imem_wdata_o           (imem_wdata_core),
      .imem_rdata_i           (imem_rdata_core),
      .imem_rvalid_i          (imem_rvalid_core),
      .imem_rerror_i          (imem_rerror_core),

      .dmem_req_o             (dmem_req_core),
      .dmem_write_o           (dmem_write_core),
      .dmem_addr_o            (dmem_addr_core),
      .dmem_wdata_o           (dmem_wdata_core),
      .dmem_wmask_o           (dmem_wmask_core),
      .dmem_rmask_o           (dmem_rmask_core_d),
      .dmem_rdata_i           (dmem_rdata_core),
      .dmem_rvalid_i          (dmem_rvalid_core),
      .dmem_rerror_i          (dmem_rerror_core),

      .edn_rnd_req_o          (edn_rnd_req),
      .edn_rnd_ack_i          (edn_rnd_ack),
      .edn_rnd_data_i         (edn_rnd_data),

      .edn_urnd_req_o         (edn_urnd_req),
      .edn_urnd_ack_i         (edn_urnd_ack),
      .edn_urnd_data_i        (edn_urnd_data),

      .insn_cnt_o             (insn_cnt_rtl),

      .bus_intg_violation_i   (bus_intg_violation),
      .illegal_bus_access_i   (illegal_bus_access_q),
      .lifecycle_escalation_i (lifecycle_escalation),

      .software_errs_fatal_i  (software_errs_fatal_q)
    );
  `else
    otbn_core #(
      .RegFile(RegFile),
      .DmemSizeByte(DmemSizeByte),
      .ImemSizeByte(ImemSizeByte),
      .RndCnstUrndLfsrSeed(RndCnstUrndLfsrSeed),
      .RndCnstUrndChunkLfsrPerm(RndCnstUrndChunkLfsrPerm)
    ) u_otbn_core (
      .clk_i,
      .rst_ni                 (rst_n),

      .start_i                (start_q),
      .done_o                 (done),
      .locked_o               (locked),

      .err_bits_o             (err_bits),

      .imem_req_o             (imem_req_core),
      .imem_addr_o            (imem_addr_core),
      .imem_wdata_o           (imem_wdata_core),
      .imem_rdata_i           (imem_rdata_core),
      .imem_rvalid_i          (imem_rvalid_core),
      .imem_rerror_i          (imem_rerror_core),

      .dmem_req_o             (dmem_req_core),
      .dmem_write_o           (dmem_write_core),
      .dmem_addr_o            (dmem_addr_core),
      .dmem_wdata_o           (dmem_wdata_core),
      .dmem_wmask_o           (dmem_wmask_core),
      .dmem_rmask_o           (dmem_rmask_core_d),
      .dmem_rdata_i           (dmem_rdata_core),
      .dmem_rvalid_i          (dmem_rvalid_core),
      .dmem_rerror_i          (dmem_rerror_core),

      .edn_rnd_req_o          (edn_rnd_req),
      .edn_rnd_ack_i          (edn_rnd_ack),
      .edn_rnd_data_i         (edn_rnd_data),

      .edn_urnd_req_o         (edn_urnd_req),
      .edn_urnd_ack_i         (edn_urnd_ack),
      .edn_urnd_data_i        (edn_urnd_data),

      .insn_cnt_o             (insn_cnt),

      .bus_intg_violation_i   (bus_intg_violation),
      .illegal_bus_access_i   (illegal_bus_access_q),
      .lifecycle_escalation_i (lifecycle_escalation),

      .software_errs_fatal_i  (software_errs_fatal_q)
    );
  `endif

  // The core can never signal a write to IMEM
  assign imem_write_core = 1'b0;


  // Asserts ===================================================================

  // All outputs should be known value after reset
  `ASSERT_KNOWN(TlODValidKnown_A, tl_o.d_valid)
  `ASSERT_KNOWN(TlOAReadyKnown_A, tl_o.a_ready)
  `ASSERT_KNOWN(IdleOKnown_A, idle_o)
  `ASSERT_KNOWN(IdleOtpOKnown_A, idle_otp_o, clk_otp_i, !rst_otp_ni)
  `ASSERT_KNOWN(IntrDoneOKnown_A, intr_done_o)
  `ASSERT_KNOWN(AlertTxOKnown_A, alert_tx_o)
  `ASSERT_KNOWN(EdnRndOKnown_A, edn_rnd_o, clk_edn_i, !rst_edn_ni)
  `ASSERT_KNOWN(EdnUrndOKnown_A, edn_urnd_o, clk_edn_i, !rst_edn_ni)
  `ASSERT_KNOWN(OtbnOtpKeyO_A, otbn_otp_key_o, clk_otp_i, !rst_otp_ni)

  // In locked state, the readable registers INSN_CNT, IMEM, and DMEM are expected to always read 0
  // when accessed from the bus.
  `ASSERT(LockedInsnCntReadsZero_A, (hw2reg.status.d == StatusLocked) |-> insn_cnt == 'd0)
  `ASSERT(NonIdleImemReadsZero_A,
      (hw2reg.status.d != StatusIdle) & imem_rvalid_bus |-> imem_rdata_bus == 'd0)
  `ASSERT(NonIdleDmemReadsZero_A,
      (hw2reg.status.d != StatusIdle) & dmem_rvalid_bus |-> dmem_rdata_bus == 'd0)

endmodule
