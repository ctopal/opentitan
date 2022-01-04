// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// An interface that gets bound into aon_timer_core to track its input and output signals. The names
// are kept in sync with the signals on aon_timer_core, so the ports can be connected with a .*

interface aon_timer_core_if (
  input logic                      clk_aon_i,
  input logic                      rst_aon_ni,

  input lc_ctrl_pkg::lc_tx_t [2:0] lc_escalate_en_i,
  input logic                      sleep_mode_i,

  // Register interface
  input aon_timer_reg_pkg::aon_timer_reg2hw_t reg2hw_i,
  input logic                      wkup_intr_o,
  input logic                      wdog_intr_o,
  input logic                      wdog_reset_req_o
);

  logic                     wkup_count_reg_wr_o;
  logic [31:0]              wkup_count_wr_data_o;
  logic                     wdog_count_reg_wr_o;
  logic [31:0]              wdog_count_wr_data_o;
endinterface
