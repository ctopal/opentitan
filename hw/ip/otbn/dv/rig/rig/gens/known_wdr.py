# Copyright lowRISC contributors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

import random
from typing import Optional

from shared.operand import ImmOperandType, RegOperandType
from shared.insn_yaml import InsnsFile

from ..config import Config
from ..model import Model
from ..program import ProgInsn, Program
from ..snippet import ProgSnippet
from ..snippet_gen import GenCont, GenRet, SnippetGen


class KnownWDR(SnippetGen):
    '''A snippet generator that generates known values (all zeros or all ones for now) for WDRs. 

    '''

    def __init__(self, cfg: Config, insns_file: InsnsFile) -> None:
        super().__init__()
  
#        self.insns = []
#        
#        for insn in insns_file.insns:
#                if not (insn.mnemonic == 'bn.xor') or (insn.mnemonic == 'bn.not'):
#                        continue
#                self.insns.append(insn)
       
        if 'bn.xor' not in insns_file.mnemonic_to_insn:
            raise RuntimeError('BN.XOR instruction not in instructions file')
    
#        if 'bn.not' not in insns_file.mnemonic_to_insn:
#            raise RuntimeError('BN.NOT instruction not in instructions file')
       
        self.insn = insns_file.mnemonic_to_insn['bn.xor']
        # BN.XOR has six operands: wrd, wrs1, wrs2, shift_type, shift_value and flag_group
        if not (len(self.insn.operands) == 6 and
                     isinstance(self.insn.operands[0].op_type, RegOperandType) and
                     self.insn.operands[0].op_type.reg_type == 'wdr' and
                     self.insn.operands[0].op_type.is_dest() and
                     isinstance(self.insn.operands[1].op_type, RegOperandType) and
                     self.insn.operands[1].op_type.reg_type == 'wdr' and
                     not self.insn.operands[1].op_type.is_dest() and
                     isinstance(self.insn.operands[2].op_type, RegOperandType) and
                     self.insn.operands[2].op_type.reg_type == 'wdr' and
                     not self.insn.operands[2].op_type.is_dest() and
                     isinstance(self.insn.operands[4].op_type, ImmOperandType)):
           raise RuntimeError('BN.XOR instruction from instructions file is not '
                               'the shape expected by the SmallVal generator.')

        self.wrd_op_type = self.insn.operands[0].op_type
        self.wrs1_op_type = self.insn.operands[1].op_type
        self.wrs2_op_type = self.insn.operands[2].op_type
        self.imm_op_type = self.insn.operands[4].op_type
        self.imm_op_type.shift = 3
        
    def gen(self,
            cont: GenCont,
            model: Model,
            program: Program) -> Optional[GenRet]:
        # Return None if this is the last instruction in the current gap
        # because we need to either jump or do an ECALL to avoid getting stuck.
        if program.get_insn_space_at(model.pc) <= 1:
            return None

        # Pick grd any old way: we can write to any register. This should
        # always succeed.
        wrd_val = model.pick_reg_operand_value(self.wrd_op_type)
        print(wrd_val, model.is_const('wdr',wrd_val))
        assert wrd_val is not None

        # Pick an operand value.
        wrs1_val = model.pick_reg_operand_value(self.wrd_op_type)
        wrs2_val = wrs1_val
        assert wrs1_val is not None
  
        shift_bits = 0
        shift_bits_encoded = self.imm_op_type.op_val_to_enc_val(shift_bits, model.pc)
        # Encoding should succeed because we made sure that imm was in range.
        assert shift_bits_encoded is not None

        shift_type = random.randint(0,1)
        
        op_vals = [wrd_val, wrs1_val, wrs2_val, shift_type, shift_bits_encoded, 0 ]

        prog_insn = ProgInsn(self.insn, op_vals, None)
        snippet = ProgSnippet(model.pc, [prog_insn])
        snippet.insert_into_program(program)

        model.update_for_insn(prog_insn)
        model.pc += 4

        return (snippet, False, model)
