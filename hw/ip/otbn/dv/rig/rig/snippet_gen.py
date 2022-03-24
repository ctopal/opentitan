# Copyright lowRISC contributors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

'''A module defining a base class for a snippet generator.

The generators in the ./gens/ subdirectory all derive from this class. To
actually generate some snippets, use the wrapper in snippet_gens.py.

'''

from typing import Callable, Optional, Tuple
from unittest import result

from shared.operand import (EnumOperandType, ImmOperandType, RegOperandType,
                            OptionOperandType)

from shared.insn_yaml import Insn, InsnsFile

from .program import Program
from .model import Model
from .snippet import Snippet

# The return type of a single generator. This is a pair: (snippet, model).
# snippet is a generated snippet. model is a Model object representing the
# state of the processor after executing the code in the snippet(s). The PC of
# the model will be the next instruction to be executed unless snippet stops
# the model, in which case it still points at the final instruction.
GenRet = Tuple[Snippet, Model]

# The return type of repeated generator calls. If the snippet is None, no
# generators managed to generate anything.
GensRet = Tuple[Optional[Snippet], Model]

# A continuation type that allows a generator to recursively generate some more
# stuff. If the boolean argument is true, the continuation will try to generate
# a snippet that causes OTBN to stop. In this case, the Snippet term in the
# GensRet will not be None.
GenCont = Callable[[Model, Program, bool], GensRet]


class SnippetGen:
    '''A parameterised sequence of instructions

    These can be added to the instructions generated so far for a given random
    binary.

    '''
    # A class-level variable that is set for generators that will end the
    # program (with an ECALL or an error)
    ends_program: bool = False

    def __init__(self) -> None:
        self.disabled = False

    def gen(self,
            cont: GenCont,
            model: Model,
            program: Program) -> Optional[GenRet]:
        '''Try to generate instructions for this type of snippet.

        On success, inserts the instructions into program, updates the model,
        and returns a GenRet tuple. See comment above the type definition for
        more information.

        On failure, leaves program and model unchanged and returns None.
        Failure is interpreted as "this snippet won't work with the current
        program state", but the generator may be retried later.

        The cont argument is a continuation, used to call out to more
        generators in order to do recursive generation. It takes a (mutable)
        model and program and picks a sequence of instructions. The paths
        through the generated code don't terminate with an ECALL but instead
        end up at the resulting model.pc.

        This will only be called when model.fuel > 0 and
        program.get_insn_space_at(model.pc) > 0.

        '''
        raise NotImplementedError('gen not implemented by subclass')

    def pick_weight(self,
                    model: Model,
                    program: Program) -> float:
        '''Pick a weight by which to multiply this generator's default weight

        This is called for each generator before we start trying to generate a
        snippet for a given program and model state. This can be used to
        disable a generator when we know it won't work (if model.fuel is too
        small, for example).

        It can also be used to alter weights depending on where we are in the
        program. For example, a generator that generates ECALL to end the
        program could decrease its weight when size is large, to avoid
        generating tiny programs by accident.

        This will only be called when model.fuel > 0 and
        program.get_insn_space_at(model.pc) > 0.

        The default implementation always returns 1.0.

        '''
        return 1.0

    def _check_insn_shape(self, insn: Optional[Insn], mnemonic: str) -> bool:
        assert insn is not None
        # Don't check ecall mnemonic
        if mnemonic == 'ecall':
            return True

        ops = insn.operands
        expected_shape = {
            'bn.xor' :
            len(ops) == 6 and
            isinstance(ops[0].op_type, RegOperandType) and
            ops[0].op_type.reg_type == 'wdr' and
            ops[0].op_type.is_dest() and
            isinstance(ops[1].op_type, RegOperandType) and
            ops[1].op_type.reg_type == 'wdr' and
            not ops[1].op_type.is_dest() and
            isinstance(ops[2].op_type, RegOperandType) and
            ops[2].op_type.reg_type == 'wdr' and
            not ops[2].op_type.is_dest() and
            isinstance(ops[4].op_type, ImmOperandType),

            'bn.not' :
            isinstance(ops[0].op_type, RegOperandType) and
            ops[0].op_type.reg_type == 'wdr' and
            ops[0].op_type.is_dest() and
            isinstance(ops[1].op_type, RegOperandType) and
            ops[1].op_type.reg_type == 'wdr' and
            not ops[1].op_type.is_dest() and
            isinstance(ops[2].op_type, EnumOperandType) and
            isinstance(ops[3].op_type, ImmOperandType),

            'bn.movr' :
            len(ops) == 4 and
            isinstance(ops[0].op_type, RegOperandType) and
            ops[0].op_type.reg_type == 'gpr' and
            not ops[0].op_type.is_dest() and
            isinstance(ops[1].op_type, RegOperandType) and
            ops[1].op_type.reg_type == 'gpr' and
            not ops[1].op_type.is_dest() and
            isinstance(ops[2].op_type, OptionOperandType) and
            isinstance(ops[3].op_type, OptionOperandType),

            'lw' :
            len(ops) == 3 and
            isinstance(ops[0].op_type, RegOperandType) and
            ops[0].op_type.reg_type == 'gpr' and
            ops[0].op_type.is_dest() and
            isinstance(ops[1].op_type, ImmOperandType) and
            isinstance(ops[2].op_type, RegOperandType) and
            ops[2].op_type.reg_type == 'gpr' and
            not ops[2].op_type.is_dest(),

            'sw' :
            len(ops) == 3 and
            isinstance(ops[0].op_type, RegOperandType) and
            ops[0].op_type.reg_type == 'gpr' and
            not ops[0].op_type.is_dest() and
            isinstance(ops[1].op_type, ImmOperandType) and
            isinstance(ops[2].op_type, RegOperandType) and
            ops[2].op_type.reg_type == 'gpr' and
            not ops[2].op_type.is_dest(),

            # BN.LID grd is destination in a sense, but it's
            # used as the indirect destination of which we
            # write to the calculated WDR. That makes it
            # source from the perspective of the RIG
            'bn.lid' :
            len(ops) == 5 and
            isinstance(ops[0].op_type, RegOperandType) and
            ops[0].op_type.reg_type == 'gpr' and
            not ops[0].op_type.is_dest() and
            isinstance(ops[1].op_type, RegOperandType) and
            ops[1].op_type.reg_type == 'gpr' and
            not ops[1].op_type.is_dest() and
            isinstance(ops[2].op_type, ImmOperandType) and
            ops[2].op_type.signed and
            isinstance(ops[3].op_type, OptionOperandType) and
            isinstance(ops[4].op_type, OptionOperandType),

            'bn.sid' :
            len(ops) == 5 and
            isinstance(ops[0].op_type, RegOperandType) and
            ops[0].op_type.reg_type == 'gpr' and
            not ops[0].op_type.is_dest() and
            isinstance(ops[1].op_type, RegOperandType) and
            ops[1].op_type.reg_type == 'gpr' and
            not ops[1].op_type.is_dest() and
            isinstance(ops[2].op_type, ImmOperandType) and
            ops[2].op_type.signed and
            isinstance(ops[3].op_type, OptionOperandType) and
            isinstance(ops[4].op_type, OptionOperandType),

            'beq' :
            len(ops) == 3 and
            isinstance(ops[0].op_type, RegOperandType) and
            ops[0].op_type.reg_type == 'gpr' and
            not ops[0].op_type.is_dest() and
            isinstance(ops[1].op_type, RegOperandType) and
            ops[1].op_type.reg_type == 'gpr' and
            not ops[1].op_type.is_dest() and
            isinstance(ops[2].op_type, ImmOperandType) and
            ops[2].op_type.signed,

            'bne' :
            len(ops) == 3 and
            isinstance(ops[0].op_type, RegOperandType) and
            ops[0].op_type.reg_type == 'gpr' and
            not ops[0].op_type.is_dest() and
            isinstance(ops[1].op_type, RegOperandType) and
            ops[1].op_type.reg_type == 'gpr' and
            not ops[1].op_type.is_dest() and
            isinstance(ops[2].op_type, ImmOperandType) and
            ops[2].op_type.signed,

            'jal' :
            len(ops) == 2 and
            isinstance(ops[0].op_type, RegOperandType) and
            ops[0].op_type.reg_type == 'gpr' and
            ops[0].op_type.is_dest() and
            isinstance(ops[1].op_type, ImmOperandType) and
            ops[1].op_type.signed,

            'jalr' :
            len(ops) == 3 and
            isinstance(ops[0].op_type, RegOperandType) and
            ops[0].op_type.reg_type == 'gpr' and
            ops[0].op_type.is_dest() and
            isinstance(ops[1].op_type, RegOperandType) and
            ops[1].op_type.reg_type == 'gpr' and
            not ops[1].op_type.is_dest() and
            isinstance(ops[2].op_type, ImmOperandType) and
            ops[2].op_type.signed,

            'loop' :
            len(ops) == 2 and
            isinstance(ops[0].op_type, RegOperandType) and
            ops[0].op_type.reg_type == 'gpr' and
            isinstance(ops[1].op_type, ImmOperandType) and
            not ops[1].op_type.signed,

            'loopi' :
            len(ops) == 2 and
            isinstance(ops[0].op_type, ImmOperandType) and
            not ops[0].op_type.signed and
            isinstance(ops[1].op_type, ImmOperandType) and
            not ops[1].op_type.signed
        }[mnemonic]

        return expected_shape

    def _get_named_insn(self, insns_file: InsnsFile, mnemonic: str) -> Insn:
        '''Get an instruction from insns_file by mnemonic

        This is used for specialized snippets that need to generate a specific
        instruction and wraps the error handling for when someone has removed
        the instruction from the file.

        '''
        insn = insns_file.mnemonic_to_insn.get(mnemonic.lower())

        if not self._check_insn_shape(insn, mnemonic.lower()):
            raise RuntimeError('Fetched instruction {} from instructions file is '
                               'not the shape expected by the generator.'.format(mnemonic.upper()))

        if insn is None:
            raise RuntimeError('No {} instruction in instructions file.'
                               .format(mnemonic.upper()))
        return insn
