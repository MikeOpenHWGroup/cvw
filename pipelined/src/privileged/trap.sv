///////////////////////////////////////////
// trap.sv
//
// Written: David_Harris@hmc.edu 9 January 2021
// Modified: dottolia@hmc.edu 14 April 2021: Add support for vectored interrupts
//
// Purpose: Handle Traps: Exceptions and Interrupts
//          See RISC-V Privileged Mode Specification 20190608 3.1.10-11
// 
// A component of the Wally configurable RISC-V project.
// 
// Copyright (C) 2021 Harvey Mudd College & Oklahoma State University
//
// MIT LICENSE
// Permission is hereby granted, free of charge, to any person obtaining a copy of this 
// software and associated documentation files (the "Software"), to deal in the Software 
// without restriction, including without limitation the rights to use, copy, modify, merge, 
// publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons 
// to whom the Software is furnished to do so, subject to the following conditions:
//
//   The above copyright notice and this permission notice shall be included in all copies or 
//   substantial portions of the Software.
//
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, 
//   INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR 
//   PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS 
//   BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, 
//   TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE 
//   OR OTHER DEALINGS IN THE SOFTWARE.
////////////////////////////////////////////////////////////////////////////////////////////////

`include "wally-config.vh"

module trap (
   input logic 		   reset, 
  (* mark_debug = "true" *) input logic 		   InstrMisalignedFaultM, InstrAccessFaultM, IllegalInstrFaultM,
  (* mark_debug = "true" *) input logic 		   BreakpointFaultM, LoadMisalignedFaultM, StoreAmoMisalignedFaultM,
  (* mark_debug = "true" *) input logic 		   LoadAccessFaultM, StoreAmoAccessFaultM, EcallFaultM, InstrPageFaultM,
  (* mark_debug = "true" *) input logic 		   LoadPageFaultM, StoreAmoPageFaultM,
  (* mark_debug = "true" *) input logic 		   mretM, sretM, 
  input logic [1:0] 	   PrivilegeModeW, NextPrivilegeModeM,
  (* mark_debug = "true" *) input logic [`XLEN-1:0]  MEPC_REGW, SEPC_REGW, STVEC_REGW, MTVEC_REGW,
  (* mark_debug = "true" *) input logic [11:0] 	   MIP_REGW, MIE_REGW, MIDELEG_REGW,
  input logic 		   STATUS_MIE, STATUS_SIE,
  input logic [`XLEN-1:0]  PCM,
  input logic [`XLEN-1:0]  IEUAdrM, 
  input logic [31:0] 	   InstrM,
  input logic 		   InstrValidM, CommittedM, 
  output logic 		   TrapM, MTrapM, STrapM, RetM,
  output logic 		   InterruptM, IntPendingM,
  output logic [`XLEN-1:0] PrivilegedNextPCM, CauseM, NextFaultMtvalM
//  output logic [11:0]     MIP_REGW, SIP_REGW, UIP_REGW, MIE_REGW, SIE_REGW, UIE_REGW,
//  input  logic            WriteMIPM, WriteSIPM, WriteUIPM, WriteMIEM, WriteSIEM, WriteUIEM
);

  logic MIntGlobalEnM, SIntGlobalEnM;
  logic ExceptionM;
  (* mark_debug = "true" *) logic [11:0] PendingIntsM, ValidIntsM; 
  //logic InterruptM;
  logic [`XLEN-1:0] PrivilegedTrapVector, PrivilegedVectoredTrapVector;

  // Determine pending enabled interrupts
  // interrupt if any sources are pending
  // & with a M stage valid bit to avoid interrupts from interrupt a nonexistent flushed instruction (in the M stage)
  // & with ~CommittedM to make sure MEPC isn't chosen so as to rerun the same instr twice
  assign MIntGlobalEnM = (PrivilegeModeW != `M_MODE) | STATUS_MIE; // if M ints enabled or lower priv 3.1.9
  assign SIntGlobalEnM = (PrivilegeModeW == `U_MODE) | ((PrivilegeModeW == `S_MODE) & STATUS_SIE); // if in lower priv mode, or if S ints enabled and not in higher priv mode 3.1.9
  assign PendingIntsM = MIP_REGW & MIE_REGW;
  assign IntPendingM = |PendingIntsM;
  assign ValidIntsM = {12{MIntGlobalEnM}} & PendingIntsM & ~MIDELEG_REGW | {12{SIntGlobalEnM}} & PendingIntsM & MIDELEG_REGW; 
  assign InterruptM = (|ValidIntsM) && InstrValidM && ~(CommittedM);  // *** RT. CommittedM is a temporary hack to prevent integer division from having an interrupt during divide.

  // Trigger Traps and RET
  // According to RISC-V Spec Section 1.6, exceptions are caused by instructions.  Interrupts are external asynchronous.
  // Traps are the union of exceptions and interrupts.
  assign ExceptionM = InstrMisalignedFaultM | InstrAccessFaultM | IllegalInstrFaultM |
                      LoadMisalignedFaultM | StoreAmoMisalignedFaultM |
                      InstrPageFaultM | LoadPageFaultM | StoreAmoPageFaultM |
                      BreakpointFaultM | EcallFaultM |
                      LoadAccessFaultM | StoreAmoAccessFaultM;
  assign TrapM = ExceptionM | InterruptM; // *** clean this up later DH
  assign MTrapM = TrapM & (NextPrivilegeModeM == `M_MODE);
  assign STrapM = TrapM & (NextPrivilegeModeM == `S_MODE) & `S_SUPPORTED;
  assign RetM = mretM | sretM;

  always_comb
      if (NextPrivilegeModeM == `S_MODE) PrivilegedTrapVector = STVEC_REGW;
      else                               PrivilegedTrapVector = MTVEC_REGW; 

  // Handle vectored traps (when mtvec/stvec csr value has bits [1:0] == 01)
  // For vectored traps, set program counter to _tvec value + 4 times the cause code
  //
  // POSSIBLE OPTIMIZATION: 
  // From 20190608 privielegd spec page 27 (3.1.7)
  // > Allowing coarser alignments in Vectored mode enables vectoring to be
  // > implemented without a hardware adder circuit.
  // For example, we could require m/stvec be aligned on 7 bits to let us replace the adder directly below with
  // [untested] PrivilegedVectoredTrapVector = {PrivilegedTrapVector[`XLEN-1:7], CauseM[3:0], 4'b0000}
  if(`VECTORED_INTERRUPTS_SUPPORTED) begin:vec
      always_comb
        if (PrivilegedTrapVector[1:0] == 2'b01 & CauseM[`XLEN-1] == 1)
          PrivilegedVectoredTrapVector = {PrivilegedTrapVector[`XLEN-1:2] + CauseM[`XLEN-3:0], 2'b00};
        else
          PrivilegedVectoredTrapVector = {PrivilegedTrapVector[`XLEN-1:2], 2'b00};
  end
  else begin
    assign PrivilegedVectoredTrapVector = {PrivilegedTrapVector[`XLEN-1:2], 2'b00};
  end

  always_comb 
    if      (TrapM)                         PrivilegedNextPCM = PrivilegedVectoredTrapVector;
    else if (mretM)                         PrivilegedNextPCM = MEPC_REGW;
    else                                    PrivilegedNextPCM = SEPC_REGW;

  // Cause priority defined in table 3.7 of 20190608 privileged spec
  // Exceptions are of lower priority than all interrupts (3.1.9)
  always_comb
    if      (reset)                 CauseM = 0; // hard reset 3.3
    else if (ValidIntsM[11])        CauseM = (1 << (`XLEN-1)) + 11; // Machine External Int
    else if (ValidIntsM[3])         CauseM = (1 << (`XLEN-1)) + 3;  // Machine Sw Int
    else if (ValidIntsM[7])         CauseM = (1 << (`XLEN-1)) + 7;  // Machine Timer Int
    else if (ValidIntsM[9])         CauseM = (1 << (`XLEN-1)) + 9;  // Supervisor External Int 
    else if (ValidIntsM[1])         CauseM = (1 << (`XLEN-1)) + 1;  // Supervisor Sw Int       
    else if (ValidIntsM[5])         CauseM = (1 << (`XLEN-1)) + 5;  // Supervisor Timer Int    
    else if (InstrPageFaultM)       CauseM = 12;
    else if (InstrAccessFaultM)     CauseM = 1;
    else if (IllegalInstrFaultM)    CauseM = 2;
    else if (InstrMisalignedFaultM) CauseM = 0;
    else if (BreakpointFaultM)      CauseM = 3;
    else if (EcallFaultM)           CauseM = {{(`XLEN-2){1'b0}}, PrivilegeModeW} + 8;
    else if (LoadMisalignedFaultM)  CauseM = 4;
    else if (StoreAmoMisalignedFaultM) CauseM = 6;
    else if (LoadPageFaultM)        CauseM = 13;
    else if (StoreAmoPageFaultM)    CauseM = 15;
    else if (LoadAccessFaultM)      CauseM = 5;
    else if (StoreAmoAccessFaultM)  CauseM = 7;
    else                            CauseM = 0;

  // MTVAL
    // 3.1.17: on instruction fetch, load, or store address misaligned access or page fault
    // mtval is written with the faulting virtual address.
    // On illegal instruction trap, mtval may be written with faulting instruction
    // For other traps (including interrupts), mtval is set to 0
    // *** hardware breakpoint is supposed to write faulting virtual address per priv p. 38
    // *** Page faults not yet implemented
    // Technically 
  
  always_comb 
    if      (InstrPageFaultM)       NextFaultMtvalM = PCM;
    else if (InstrAccessFaultM)     NextFaultMtvalM = PCM;
    else if (IllegalInstrFaultM)    NextFaultMtvalM = {{(`XLEN-32){1'b0}}, InstrM};
    else if (InstrMisalignedFaultM) NextFaultMtvalM = IEUAdrM;
    else if (EcallFaultM)           NextFaultMtvalM = 0;
    else if (BreakpointFaultM)      NextFaultMtvalM = PCM;
    else if (LoadMisalignedFaultM)  NextFaultMtvalM = IEUAdrM;
    else if (StoreAmoMisalignedFaultM) NextFaultMtvalM = IEUAdrM;
    else if (LoadPageFaultM)        NextFaultMtvalM = IEUAdrM;
    else if (StoreAmoPageFaultM)    NextFaultMtvalM = IEUAdrM;
    else if (LoadAccessFaultM)      NextFaultMtvalM = IEUAdrM;
    else if (StoreAmoAccessFaultM)  NextFaultMtvalM = IEUAdrM;
    else                            NextFaultMtvalM = 0;
endmodule
