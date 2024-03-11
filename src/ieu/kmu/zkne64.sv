///////////////////////////////////////////
// zkne64.sv
//
// Written: kelvin.tran@okstate.edu, james.stine@okstate.edu
// Created: 21 November 2023
// Modified: 31 January 2024
//
// Purpose: RISC-V ZKNE top level unit for 64-bit instructions: RV64 NIST AES Encryption
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// https://github.com/openhwgroup/cvw
// 
// Copyright (C) 2021-24 Harvey Mudd College & Oklahoma State University
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the “License”); you may not use this file 
// except in compliance with the License, or, at your option, the Apache License version 2.0. You 
// may obtain a copy of the License at
//
// https://solderpad.org/licenses/SHL-2.1/
//
// Unless required by applicable law or agreed to in writing, any work distributed under the 
// License is distributed on an “AS IS” BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, 
// either express or implied. See the License for the specific language governing permissions 
// and limitations under the License.
////////////////////////////////////////////////////////////////////////////////////////////////

module zkne64 #(parameter WIDTH=32) (
   input  logic [WIDTH-1:0] A, B,
   input  logic [6:0] 	    Funct7,
   input  logic [3:0] 	    RNUM,
   input  logic [2:0] 	    ZKNESelect,
   output logic [WIDTH-1:0] ZKNEResult
);
   
   logic [63:0] 	     aes64esRes, aes64esmRes, aes64ks1iRes, aes64ks2Res;
   
   // RV64
   aes64es   aes64es(.rs1(A), .rs2(B), .DataOut(aes64esRes));
   aes64esm  aes64esm(.rs1(A), .rs2(B), .DataOut(aes64esmRes));
   aes64ks1i aes64ks1i(.roundnum(RNUM), .rs1(A), .rd(aes64ks1iRes));
   aes64ks2  aes64ks2(.rs2(B), .rs1(A), .rd(aes64ks2Res));
   
   // 010 is a placeholder to match the select of ZKND's AES64KS1I since they share some instruction
   mux5 #(WIDTH) zknemux(aes64esRes, aes64esmRes, 64'b0, aes64ks1iRes, aes64ks2Res, ZKNESelect, ZKNEResult);   
endmodule
