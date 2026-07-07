# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


@cocotb.test()
async def test_project(dut):
    dut._log.info("Start")

    clock = Clock(dut.clk, 40, unit="ns")  # 25 MHz
    cocotb.start_soon(clock.start())

    # Reset
    dut.ena.value   = 1
    dut.ui_in.value = 1   # rx idles high
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 5)

    # After reset, UART tx should idle high (uo_out[0] = 1)
    dut._log.info(f"uo_out = {dut.uo_out.value}")
    assert (int(dut.uo_out.value) & 0x01) == 1, \
        f"Expected tx (uo_out[0]) = 1 after reset, got {dut.uo_out.value}"

    dut._log.info("PASS: UART tx idles high after reset")
