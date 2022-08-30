/*

Copyright (c) 2014-2021 Alex Forencich

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

*/

// Language: Verilog 2001

`timescale 1ns / 1ps

/*
 * AXI4-Stream asynchronous FIFO
 */
module axis_async_fifo #
(
    // FIFO depth in words
    // KEEP_WIDTH words per cycle if KEEP_ENABLE set
    // Rounded up to nearest power of 2 cycles
    parameter DEPTH = 4096,
    // Width of AXI stream interfaces in bits
    parameter DATA_WIDTH = 8,
    // Propagate tkeep signal
    // If disabled, tkeep assumed to be 1'b1
    parameter KEEP_ENABLE = (DATA_WIDTH>8),
    // tkeep signal width (words per cycle)
    parameter KEEP_WIDTH = (DATA_WIDTH/8),
    // Propagate tlast signal
    parameter LAST_ENABLE = 1,
    // Propagate tid signal
    parameter ID_ENABLE = 0,
    // tid signal width
    parameter ID_WIDTH = 8,
    // Propagate tdest signal
    parameter DEST_ENABLE = 0,
    // tdest signal width
    parameter DEST_WIDTH = 8,
    // Propagate tuser signal
    parameter USER_ENABLE = 1,
    // tuser signal width
    parameter USER_WIDTH = 1,
    // number of output pipeline registers
    parameter PIPELINE_OUTPUT = 2,
    // Frame FIFO mode - operate on frames instead of cycles
    // When set, m_axis_tvalid will not be deasserted within a frame
    // Requires LAST_ENABLE set
    parameter FRAME_FIFO = 0,
    // tuser value for bad frame marker
    parameter USER_BAD_FRAME_VALUE = 1'b1,
    // tuser mask for bad frame marker
    parameter USER_BAD_FRAME_MASK = 1'b1,
    // Drop frames larger than FIFO
    // Requires FRAME_FIFO set
    parameter DROP_OVERSIZE_FRAME = FRAME_FIFO,
    // Drop frames marked bad
    // Requires FRAME_FIFO and DROP_OVERSIZE_FRAME set
    parameter DROP_BAD_FRAME = 0,
    // Drop incoming frames when full
    // When set, s_axis_tready is always asserted
    // Requires FRAME_FIFO and DROP_OVERSIZE_FRAME set
    parameter DROP_WHEN_FULL = 0
)
(
    /*
     * AXI input
     */
    input  wire                   s_clk,
    input  wire                   s_rst,
    input  wire [DATA_WIDTH-1:0]  s_axis_tdata,
    input  wire [KEEP_WIDTH-1:0]  s_axis_tkeep,
    input  wire                   s_axis_tvalid,
    output wire                   s_axis_tready,
    input  wire                   s_axis_tlast,
    input  wire [ID_WIDTH-1:0]    s_axis_tid,
    input  wire [DEST_WIDTH-1:0]  s_axis_tdest,
    input  wire [USER_WIDTH-1:0]  s_axis_tuser,

    /*
     * AXI output
     */
    input  wire                   m_clk,
    input  wire                   m_rst,
    output wire [DATA_WIDTH-1:0]  m_axis_tdata,
    output wire [KEEP_WIDTH-1:0]  m_axis_tkeep,
    output wire                   m_axis_tvalid,
    input  wire                   m_axis_tready,
    output wire                   m_axis_tlast,
    output wire [ID_WIDTH-1:0]    m_axis_tid,
    output wire [DEST_WIDTH-1:0]  m_axis_tdest,
    output wire [USER_WIDTH-1:0]  m_axis_tuser,

    /*
     * Status
     */
    output wire                   s_status_overflow,
    output wire                   s_status_bad_frame,
    output wire                   s_status_good_frame,
    output wire                   m_status_overflow,
    output wire                   m_status_bad_frame,
    output wire                   m_status_good_frame
);

parameter ADDR_WIDTH = (KEEP_ENABLE && KEEP_WIDTH > 1) ? $clog2(DEPTH/KEEP_WIDTH) : $clog2(DEPTH);

// check configuration
initial begin
    if (PIPELINE_OUTPUT < 1) begin
        $error("Error: PIPELINE_OUTPUT must be at least 1 (instance %m)");
        $finish;
    end

    if (FRAME_FIFO && !LAST_ENABLE) begin
        $error("Error: FRAME_FIFO set requires LAST_ENABLE set (instance %m)");
        $finish;
    end

    if (DROP_OVERSIZE_FRAME && !FRAME_FIFO) begin
        $error("Error: DROP_OVERSIZE_FRAME set requires FRAME_FIFO set (instance %m)");
        $finish;
    end

    if (DROP_BAD_FRAME && !(FRAME_FIFO && DROP_OVERSIZE_FRAME)) begin
        $error("Error: DROP_BAD_FRAME set requires FRAME_FIFO and DROP_OVERSIZE_FRAME set (instance %m)");
        $finish;
    end

    if (DROP_WHEN_FULL && !(FRAME_FIFO && DROP_OVERSIZE_FRAME)) begin
        $error("Error: DROP_WHEN_FULL set requires FRAME_FIFO and DROP_OVERSIZE_FRAME set (instance %m)");
        $finish;
    end

    if (DROP_BAD_FRAME && (USER_BAD_FRAME_MASK & {USER_WIDTH{1'b1}}) == 0) begin
        $error("Error: Invalid USER_BAD_FRAME_MASK value (instance %m)");
        $finish;
    end
end

localparam KEEP_OFFSET = DATA_WIDTH;
localparam LAST_OFFSET = KEEP_OFFSET + (KEEP_ENABLE ? KEEP_WIDTH : 0);
localparam ID_OFFSET   = LAST_OFFSET + (LAST_ENABLE ? 1          : 0);
localparam DEST_OFFSET = ID_OFFSET   + (ID_ENABLE   ? ID_WIDTH   : 0);
localparam USER_OFFSET = DEST_OFFSET + (DEST_ENABLE ? DEST_WIDTH : 0);
localparam WIDTH       = USER_OFFSET + (USER_ENABLE ? USER_WIDTH : 0);

parameter PORTS = "";

reg [ADDR_WIDTH:0] wr_ptr_reg;
reg [ADDR_WIDTH:0] wr_ptr_cur_reg;
reg [ADDR_WIDTH:0] wr_ptr_gray_reg_n;
reg [ADDR_WIDTH:0] wr_ptr_gray_reg;
reg [ADDR_WIDTH:0] wr_ptr_sync_gray_reg;
reg [ADDR_WIDTH:0] wr_ptr_cur_gray_reg;
reg [ADDR_WIDTH:0] rd_ptr_reg;
reg [ADDR_WIDTH:0] rd_ptr_gray_reg_n;
reg [ADDR_WIDTH:0] rd_ptr_gray_reg;

reg [ADDR_WIDTH:0] wr_ptr_temp;
wire [ADDR_WIDTH:0] rd_ptr_inc;

reg [ADDR_WIDTH:0] wr_ptr_gray_sync1_reg;
reg [ADDR_WIDTH:0] wr_ptr_gray_sync2_reg;
wire [ADDR_WIDTH:0] rd_ptr_gray_sync2_reg;

reg wr_ptr_update_valid_reg;
reg wr_ptr_update_reg_n;
reg wr_ptr_update_reg;
reg wr_ptr_update_sync2_reg;
wire wr_ptr_update_sync3_reg;
reg wr_ptr_update_ack_sync2_reg;

wire s_rst_sync3_reg;
wire m_rst_sync3_reg;

wire [WIDTH-1:0] s_axis;

reg [PIPELINE_OUTPUT-1:0] m_axis_tvalid_pipe_reg;

reg                   mem_w_v_li;
wire [ADDR_WIDTH-1:0] mem_w_addr_li = wr_ptr_cur_reg[ADDR_WIDTH-1:0];
wire [WIDTH-1:0]      mem_w_data_li = s_axis;
reg                   mem_r_v_li;
wire [ADDR_WIDTH-1:0] mem_r_addr_li = rd_ptr_reg[ADDR_WIDTH-1:0];
wire [WIDTH-1:0]      mem_r_data_lo;


//reg [WIDTH-1:0] mem[(2**ADDR_WIDTH)-1:0];
if (PORTS == "gf_14") begin: gf_14
mem_1r1w_sync #(
   .width_p(WIDTH)
  ,.els_p(2**ADDR_WIDTH)
) mem (
   .w_clk_i(s_clk)
  ,.w_v_i(mem_w_v_li)
  ,.w_addr_i(mem_w_addr_li)
  ,.w_data_i(mem_w_data_li)
  ,.r_clk_i(m_clk)
  ,.r_v_i(mem_r_v_li)
  ,.r_addr_i(mem_r_addr_li)
  ,.r_data_o(mem_r_data_lo)
);
end else begin: xilinx

mem_1r1w_sync_fpga #(
   .width_p(WIDTH)
  ,.els_p(2**ADDR_WIDTH)
  ,.pipeline_output_p(PIPELINE_OUTPUT)
) mem (
   .w_clk_i(s_clk)
  ,.w_v_i(mem_w_v_li)
  ,.w_addr_i(mem_w_addr_li)
  ,.w_data_i(mem_w_data_li)
  ,.r_clk_i(m_clk)
  ,.r_v_i(mem_r_v_li)
  ,.r_addr_i(mem_r_addr_li)
  ,.r_data_o(mem_r_data_lo)
  ,.output_ready_i(m_axis_tready)
  ,.valid_pipe_reg_i(m_axis_tvalid_pipe_reg)
);
end

// full when first TWO MSBs do NOT match, but rest matches
// (gray code equivalent of first MSB different but rest same)
wire full = wr_ptr_gray_reg == (rd_ptr_gray_sync2_reg ^ {2'b11, {ADDR_WIDTH-1{1'b0}}});
wire full_cur = wr_ptr_cur_gray_reg == (rd_ptr_gray_sync2_reg ^ {2'b11, {ADDR_WIDTH-1{1'b0}}});
// empty when pointers match exactly
wire empty = rd_ptr_gray_reg == (FRAME_FIFO ? wr_ptr_gray_sync1_reg : wr_ptr_gray_sync2_reg);
// overflow within packet
wire full_wr = wr_ptr_reg == (wr_ptr_cur_reg ^ {1'b1, {ADDR_WIDTH{1'b0}}});

reg s_frame_reg;
reg m_frame_reg;

reg drop_frame_reg;
reg send_frame_reg;
reg overflow_reg;
reg bad_frame_reg;
reg good_frame_reg;

reg m_drop_frame_reg;
reg m_terminate_frame_reg;

reg overflow_sync1_reg_n;
reg overflow_sync1_reg;
reg overflow_sync3_reg;
reg overflow_sync4_reg;

reg bad_frame_sync1_reg_n;
reg bad_frame_sync1_reg;
reg bad_frame_sync3_reg;
reg bad_frame_sync4_reg;

reg good_frame_sync1_reg_n;
reg good_frame_sync1_reg;
reg good_frame_sync3_reg;
reg good_frame_sync4_reg;

assign s_axis_tready = (FRAME_FIFO ? (!full_cur || (full_wr && DROP_OVERSIZE_FRAME) || DROP_WHEN_FULL) : !full) && !s_rst_sync3_reg;

generate
    assign s_axis[DATA_WIDTH-1:0] = s_axis_tdata;
    if (KEEP_ENABLE) assign s_axis[KEEP_OFFSET +: KEEP_WIDTH] = s_axis_tkeep;
    if (LAST_ENABLE) assign s_axis[LAST_OFFSET]               = s_axis_tlast;
    if (ID_ENABLE)   assign s_axis[ID_OFFSET   +: ID_WIDTH]   = s_axis_tid;
    if (DEST_ENABLE) assign s_axis[DEST_OFFSET +: DEST_WIDTH] = s_axis_tdest;
    if (USER_ENABLE) assign s_axis[USER_OFFSET +: USER_WIDTH] = s_axis_tuser;
endgenerate

wire                   m_axis_tvalid_pipe = m_axis_tvalid_pipe_reg[PIPELINE_OUTPUT-1];

wire [DATA_WIDTH-1:0]  m_axis_tdata_pipe  = mem_r_data_lo[DATA_WIDTH-1:0];
wire [KEEP_WIDTH-1:0]  m_axis_tkeep_pipe  = KEEP_ENABLE ? mem_r_data_lo[KEEP_OFFSET +: KEEP_WIDTH] : {KEEP_WIDTH{1'b1}};
wire                   m_axis_tlast_pipe  = LAST_ENABLE ? mem_r_data_lo[LAST_OFFSET] : 1'b1;
wire [ID_WIDTH-1:0]    m_axis_tid_pipe    = ID_ENABLE   ? mem_r_data_lo[ID_OFFSET +: ID_WIDTH] : {ID_WIDTH{1'b0}};
wire [DEST_WIDTH-1:0]  m_axis_tdest_pipe  = DEST_ENABLE ? mem_r_data_lo[DEST_OFFSET +: DEST_WIDTH] : {DEST_WIDTH{1'b0}};
wire [USER_WIDTH-1:0]  m_axis_tuser_pipe  = USER_ENABLE ? mem_r_data_lo[USER_OFFSET +: USER_WIDTH] : {USER_WIDTH{1'b0}};

assign m_axis_tvalid = m_axis_tvalid_pipe;

assign m_axis_tdata = m_axis_tdata_pipe;
assign m_axis_tkeep = m_axis_tkeep_pipe;
assign m_axis_tlast = (m_terminate_frame_reg ? 1'b1 : m_axis_tlast_pipe);
assign m_axis_tid   = m_axis_tid_pipe;
assign m_axis_tdest = m_axis_tdest_pipe;
assign m_axis_tuser = (m_terminate_frame_reg ? USER_BAD_FRAME_VALUE : m_axis_tuser_pipe);

assign s_status_overflow = overflow_reg;
assign s_status_bad_frame = bad_frame_reg;
assign s_status_good_frame = good_frame_reg;

assign m_status_overflow = overflow_sync3_reg ^ overflow_sync4_reg;
assign m_status_bad_frame = bad_frame_sync3_reg ^ bad_frame_sync4_reg;
assign m_status_good_frame = good_frame_sync3_reg ^ good_frame_sync4_reg;

/*
wire s_rst_sync_oclk_data_lo;
bsg_launch_sync_sync #(
   .width_p(1)
  ,.use_negedge_for_launch_p(0)
  ,.use_async_reset_p(1)
) s_rst_sync (
   .iclk_i(m_clk)
  ,.iclk_reset_i(m_rst)
  ,.oclk_i(s_clk)
  ,.iclk_data_i(1'b1)
  ,.iclk_data_o() // UNUSED
  ,.oclk_data_o(s_rst_sync_oclk_data_lo)
);
assign s_rst_sync3_reg = ~s_rst_sync_oclk_data_lo;
*/
arst_sync s_rst_sync (
   .async_reset_i(m_rst)
  ,.clk_i(s_clk)
  ,.sync_reset_o(s_rst_sync3_reg)
);
/*
wire m_rst_sync_oclk_data_lo;
bsg_launch_sync_sync #(
   .width_p(1)
  ,.use_negedge_for_launch_p(0)
  ,.use_async_reset_p(1)
) m_rst_sync (
   .iclk_i(s_clk)
  ,.iclk_reset_i(s_rst)
  ,.oclk_i(m_clk)
  ,.iclk_data_i(1'b1)
  ,.iclk_data_o() // UNUSED
  ,.oclk_data_o(m_rst_sync_oclk_data_lo)
);
assign m_rst_sync3_reg = ~m_rst_sync_oclk_data_lo;
*/

arst_sync m_rst_sync (
   .async_reset_i(s_rst)
  ,.clk_i(m_clk)
  ,.sync_reset_o(m_rst_sync3_reg)
);

// Write logic
always_ff @(posedge s_clk) begin
    overflow_reg <= 1'b0;
    bad_frame_reg <= 1'b0;
    good_frame_reg <= 1'b0;

    if (FRAME_FIFO && wr_ptr_update_valid_reg) begin
        // have updated pointer to sync
        if (wr_ptr_update_reg == wr_ptr_update_ack_sync2_reg) begin
            // no sync in progress; sync update
            wr_ptr_update_valid_reg <= 1'b0;
            wr_ptr_sync_gray_reg <= wr_ptr_gray_reg;
        end
    end

    if (s_axis_tready && s_axis_tvalid && LAST_ENABLE) begin
        // track input frame status
        s_frame_reg <= !s_axis_tlast;
    end

    if (s_rst_sync3_reg && LAST_ENABLE) begin
        // if sink side is reset during transfer, drop partial frame
        if (s_frame_reg && !(s_axis_tready && s_axis_tvalid && s_axis_tlast)) begin
            drop_frame_reg <= 1'b1;
        end
        if (s_axis_tready && s_axis_tvalid && !s_axis_tlast) begin
            drop_frame_reg <= 1'b1;
        end
    end

    if (s_axis_tready && s_axis_tvalid) begin
        // transfer in
        if (!FRAME_FIFO) begin
            // normal FIFO mode
            if (drop_frame_reg && LAST_ENABLE) begin
                // currently dropping frame
                // (only for frame transfers interrupted by sink reset)
                if (s_axis_tlast) begin
                    // end of frame, clear drop flag
                    drop_frame_reg <= 1'b0;
                end
            end else begin
                // update pointers
                wr_ptr_reg <= wr_ptr_reg + 1;
            end
        end else if ((full_cur && DROP_WHEN_FULL) || (full_wr && DROP_OVERSIZE_FRAME) || drop_frame_reg) begin
            // full, packet overflow, or currently dropping frame
            // drop frame
            drop_frame_reg <= 1'b1;
            if (s_axis_tlast) begin
                // end of frame, reset write pointer
                wr_ptr_cur_reg <= wr_ptr_reg;
                wr_ptr_cur_gray_reg <= wr_ptr_reg ^ (wr_ptr_reg >> 1);
                drop_frame_reg <= 1'b0;
                overflow_reg <= 1'b1;
            end
        end else begin
            wr_ptr_cur_reg <= (wr_ptr_cur_reg + 1);
            wr_ptr_cur_gray_reg <= (wr_ptr_cur_reg + 1) ^ ((wr_ptr_cur_reg + 1) >> 1);
            if (s_axis_tlast || (!DROP_OVERSIZE_FRAME && (full_wr || send_frame_reg))) begin
                // end of frame or send frame
                send_frame_reg <= !s_axis_tlast;
                if (s_axis_tlast && DROP_BAD_FRAME && USER_BAD_FRAME_MASK & ~(s_axis_tuser ^ USER_BAD_FRAME_VALUE)) begin
                    // bad packet, reset write pointer
                    wr_ptr_cur_reg <= wr_ptr_reg;
                    wr_ptr_cur_gray_reg <= wr_ptr_reg ^ (wr_ptr_reg >> 1);
                    bad_frame_reg <= 1'b1;
                end else begin
                    // good packet or packet overflow, update write pointer
                    wr_ptr_reg <= (wr_ptr_cur_reg + 1);
                    if (wr_ptr_update_reg == wr_ptr_update_ack_sync2_reg) begin
                        // no sync in progress; sync update
                        wr_ptr_update_valid_reg <= 1'b0;
                        wr_ptr_sync_gray_reg <= (wr_ptr_cur_reg + 1) ^ ((wr_ptr_cur_reg + 1) >> 1);
                    end else begin
                        // sync in progress; flag it for later
                        wr_ptr_update_valid_reg <= 1'b1;
                    end

                    good_frame_reg <= s_axis_tlast;
                end
            end
        end
    end else if (s_axis_tvalid && full_wr && FRAME_FIFO && !DROP_OVERSIZE_FRAME) begin
        // data valid with packet overflow
        // update write pointer
        send_frame_reg <= 1'b1;
        wr_ptr_reg <= wr_ptr_cur_reg;

        if (wr_ptr_update_reg == wr_ptr_update_ack_sync2_reg) begin
            // no sync in progress; sync update
            wr_ptr_update_valid_reg <= 1'b0;
            wr_ptr_sync_gray_reg <= wr_ptr_cur_reg ^ (wr_ptr_cur_reg >> 1);
        end else begin
            // sync in progress; flag it for later
            wr_ptr_update_valid_reg <= 1'b1;
        end
    end

    if (s_rst_sync3_reg) begin
        wr_ptr_reg <= {ADDR_WIDTH+1{1'b0}};
        wr_ptr_cur_reg <= {ADDR_WIDTH+1{1'b0}};
        wr_ptr_sync_gray_reg <= {ADDR_WIDTH+1{1'b0}};
        wr_ptr_cur_gray_reg <= {ADDR_WIDTH+1{1'b0}};

        wr_ptr_update_valid_reg <= 1'b0;
    end

    if (s_rst) begin
        wr_ptr_reg <= {ADDR_WIDTH+1{1'b0}};
        wr_ptr_cur_reg <= {ADDR_WIDTH+1{1'b0}};
        wr_ptr_sync_gray_reg <= {ADDR_WIDTH+1{1'b0}};
        wr_ptr_cur_gray_reg <= {ADDR_WIDTH+1{1'b0}};

        wr_ptr_update_valid_reg <= 1'b0;

        s_frame_reg <= 1'b0;

        drop_frame_reg <= 1'b0;
        send_frame_reg <= 1'b0;
        overflow_reg <= 1'b0;
        bad_frame_reg <= 1'b0;
        good_frame_reg <= 1'b0;
    end
end

// pointer synchronization

bsg_launch_sync_sync #(
   .width_p(ADDR_WIDTH + 1)
  ,.use_negedge_for_launch_p(0)
  ,.use_async_reset_p(0)
) rd_ptr_gray_reg_sync (
   .iclk_i(m_clk)
  ,.iclk_reset_i(m_rst)
  ,.oclk_i(s_clk)
  ,.iclk_data_i(rd_ptr_gray_reg_n)
  ,.iclk_data_o(rd_ptr_gray_reg)
  ,.oclk_data_o(rd_ptr_gray_sync2_reg)
);

always_ff @(posedge m_clk) begin
    if(FRAME_FIFO) begin
        if (wr_ptr_update_sync2_reg ^ wr_ptr_update_sync3_reg) begin
            wr_ptr_gray_sync1_reg <= wr_ptr_sync_gray_reg;
        end
        if (m_rst_sync3_reg) begin
            wr_ptr_gray_sync1_reg <= {ADDR_WIDTH+1{1'b0}};
        end
    end
end

if (FRAME_FIFO == 0) begin: frameless

  bsg_launch_sync_sync #(
     .width_p(ADDR_WIDTH + 1)
    ,.use_negedge_for_launch_p(0)
    ,.use_async_reset_p(0)
  ) wr_ptr_gray_reg_sync (
     .iclk_i(s_clk)
    ,.iclk_reset_i(s_rst)
    ,.oclk_i(m_clk)
    ,.iclk_data_i(wr_ptr_gray_reg_n)
    ,.iclk_data_o(wr_ptr_gray_reg)
    ,.oclk_data_o(wr_ptr_gray_sync2_reg)
  );

end else begin: frame

  always_ff @(posedge s_clk) begin
    if(s_rst) begin
      wr_ptr_gray_reg <= '0;
    end else begin
      wr_ptr_gray_reg <= wr_ptr_gray_reg_n;
    end
  end

end
bsg_launch_sync_sync #(
   .width_p(1)
  ,.use_negedge_for_launch_p(0)
  ,.use_async_reset_p(0)
) wr_ptr_update_reg_sync (
   .iclk_i(s_clk)
  ,.iclk_reset_i(s_rst)
  ,.oclk_i(m_clk)
  ,.iclk_data_i(wr_ptr_update_reg_n)
  ,.iclk_data_o(wr_ptr_update_reg)
  ,.oclk_data_o(wr_ptr_update_sync2_reg)
);

bsg_launch_sync_sync #(
   .width_p(1)
  ,.use_negedge_for_launch_p(0)
  ,.use_async_reset_p(0)
) wr_ptr_update_reg_ack_sync (
   .iclk_i(m_clk)
  ,.iclk_reset_i(m_rst)
  ,.oclk_i(s_clk)
  ,.iclk_data_i(wr_ptr_update_sync2_reg)
  ,.iclk_data_o(wr_ptr_update_sync3_reg)
  ,.oclk_data_o(wr_ptr_update_ack_sync2_reg)
);


// status synchronization
always_ff @(posedge m_clk) begin
    overflow_sync4_reg <= overflow_sync3_reg;
    bad_frame_sync4_reg <= bad_frame_sync3_reg;
    good_frame_sync4_reg <= good_frame_sync3_reg;

    if (m_rst) begin
        overflow_sync4_reg <= 1'b0;
        bad_frame_sync4_reg <= 1'b0;
        good_frame_sync4_reg <= 1'b0;
    end
end

assign overflow_sync1_reg_n   = overflow_sync1_reg ^ overflow_reg;
assign bad_frame_sync1_reg_n  = bad_frame_sync1_reg ^ bad_frame_reg;
assign good_frame_sync1_reg_n = good_frame_sync1_reg ^ good_frame_reg;
bsg_launch_sync_sync #(
   .width_p(1)
  ,.use_negedge_for_launch_p(0)
  ,.use_async_reset_p(0)
) overflow_reg_sync (
   .iclk_i(s_clk)
  ,.iclk_reset_i(s_rst)
  ,.oclk_i(m_clk)
  ,.iclk_data_i(overflow_sync1_reg_n)
  ,.iclk_data_o(overflow_sync1_reg)
  ,.oclk_data_o(overflow_sync3_reg)
);
bsg_launch_sync_sync #(
   .width_p(1)
  ,.use_negedge_for_launch_p(0)
  ,.use_async_reset_p(0)
) bad_frame_reg_sync (
   .iclk_i(s_clk)
  ,.iclk_reset_i(s_rst)
  ,.oclk_i(m_clk)
  ,.iclk_data_i(bad_frame_sync1_reg_n)
  ,.iclk_data_o(bad_frame_sync1_reg)
  ,.oclk_data_o(bad_frame_sync3_reg)
);
bsg_launch_sync_sync #(
   .width_p(1)
  ,.use_negedge_for_launch_p(0)
  ,.use_async_reset_p(0)
) good_frame_reg_sync (
   .iclk_i(s_clk)
  ,.iclk_reset_i(s_rst)
  ,.oclk_i(m_clk)
  ,.iclk_data_i(good_frame_sync1_reg_n)
  ,.iclk_data_o(good_frame_sync1_reg)
  ,.oclk_data_o(good_frame_sync3_reg)
);


// Read logic
integer j;

assign rd_ptr_inc = rd_ptr_reg + (ADDR_WIDTH+1)'(1'b1);

always_ff @(posedge m_clk) begin
    if (m_axis_tready) begin
        // output ready; invalidate stage
        m_axis_tvalid_pipe_reg[PIPELINE_OUTPUT-1] <= 1'b0;
        m_terminate_frame_reg <= 1'b0;
    end

    for (j = PIPELINE_OUTPUT-1; j > 0; j = j - 1) begin
        if (m_axis_tready || ((~m_axis_tvalid_pipe_reg) >> j)) begin
            // output ready or bubble in pipeline; transfer down pipeline
            m_axis_tvalid_pipe_reg[j] <= m_axis_tvalid_pipe_reg[j-1];
            m_axis_tvalid_pipe_reg[j-1] <= 1'b0;
        end
    end

    if (m_axis_tready || ~m_axis_tvalid_pipe_reg) begin
        // output ready or bubble in pipeline; read new data from FIFO
        m_axis_tvalid_pipe_reg[0] <= 1'b0;
        if (!empty && !m_rst_sync3_reg && !m_drop_frame_reg) begin
            // not empty, increment pointer
            m_axis_tvalid_pipe_reg[0] <= 1'b1;
            rd_ptr_reg <= rd_ptr_inc;
        end
    end

    if (m_axis_tvalid && LAST_ENABLE) begin
        // track output frame status
        if (m_axis_tlast && m_axis_tready) begin
            m_frame_reg <= 1'b0;
        end else begin
            m_frame_reg <= 1'b1;
        end
    end

    if (m_drop_frame_reg && (m_axis_tready || !m_axis_tvalid_pipe) && LAST_ENABLE) begin
        // terminate frame
        // (only for frame transfers interrupted by source reset)
        m_axis_tvalid_pipe_reg[PIPELINE_OUTPUT-1] <= 1'b1;
        m_terminate_frame_reg <= 1'b1;
        m_drop_frame_reg <= 1'b0;
    end

    if (m_rst_sync3_reg && LAST_ENABLE) begin
        // if source side is reset during transfer, drop partial frame
        // empty output pipeline, except for last stage
        if (PIPELINE_OUTPUT > 1) begin
            m_axis_tvalid_pipe_reg[PIPELINE_OUTPUT-2:0] <= 0;
        end

        if (m_frame_reg && (!m_axis_tvalid || (m_axis_tvalid && !m_axis_tlast)) &&
                !(m_drop_frame_reg || m_terminate_frame_reg)) begin
            // terminate frame
            m_drop_frame_reg <= 1'b1;
        end
    end

    if (m_rst_sync3_reg) begin
        rd_ptr_reg <= {ADDR_WIDTH+1{1'b0}};
    end

    if (m_rst) begin
        rd_ptr_reg <= {ADDR_WIDTH+1{1'b0}};
        m_axis_tvalid_pipe_reg <= {PIPELINE_OUTPUT{1'b0}};
        m_frame_reg <= 1'b0;
        m_drop_frame_reg <= 1'b0;
        m_terminate_frame_reg <= 1'b0;
    end
end

// Comb logic for rd_ptr_gray_reg (m_clk)
always @(*) begin
    rd_ptr_gray_reg_n = rd_ptr_gray_reg;
    mem_r_v_li = 1'b0;
    if(m_rst_sync3_reg) begin
        rd_ptr_gray_reg_n = {ADDR_WIDTH+1{1'b0}};
    end else if (m_axis_tready || ~m_axis_tvalid_pipe_reg) begin
        // output ready or bubble in pipeline; read new data from FIFO
        mem_r_v_li = 1'b1;
        if (!empty && !m_rst_sync3_reg && !m_drop_frame_reg) begin
            // not empty, increment pointer
            rd_ptr_gray_reg_n = rd_ptr_inc ^ ((rd_ptr_inc) >> 1);
        end
    end
end
// Comb logic for wr_ptr_update_reg, wr_ptr_gray_reg (s_clk)
always @(*) begin
    wr_ptr_update_reg_n = wr_ptr_update_reg;
    wr_ptr_gray_reg_n = wr_ptr_gray_reg;
    mem_w_v_li = 1'b0;
    if (FRAME_FIFO && wr_ptr_update_valid_reg) begin
        // have updated pointer to sync
        if (wr_ptr_update_reg == wr_ptr_update_ack_sync2_reg) begin
            // no sync in progress; sync update
            wr_ptr_update_reg_n = !wr_ptr_update_ack_sync2_reg;
        end
    end

    if (s_axis_tready && s_axis_tvalid) begin
        // transfer in
        if (!FRAME_FIFO) begin
            // normal FIFO mode
            mem_w_v_li = 1'b1;
            if (drop_frame_reg && LAST_ENABLE) begin
            end else begin
                // update pointers
                wr_ptr_gray_reg_n = (wr_ptr_reg + 1) ^ ((wr_ptr_reg + 1) >> 1);
            end

        end else if ((full_cur && DROP_WHEN_FULL) || (full_wr && DROP_OVERSIZE_FRAME) || drop_frame_reg) begin
            // full, packet overflow, or currently dropping frame
            // drop frame
        end else begin
            mem_w_v_li = 1'b1;
            if (s_axis_tlast || (!DROP_OVERSIZE_FRAME && (full_wr || send_frame_reg))) begin
                // end of frame or send frame
                if (s_axis_tlast && DROP_BAD_FRAME && USER_BAD_FRAME_MASK & ~(s_axis_tuser ^ USER_BAD_FRAME_VALUE)) begin
                    // bad packet, reset write pointer
                end else begin
                    // good packet or packet overflow, update write pointer
                    wr_ptr_gray_reg_n = (wr_ptr_cur_reg + 1) ^ ((wr_ptr_cur_reg + 1) >> 1);
                    if (wr_ptr_update_reg == wr_ptr_update_ack_sync2_reg) begin
                        // no sync in progress; sync update
                        wr_ptr_update_reg_n = !wr_ptr_update_ack_sync2_reg;
                    end
                end
            end
        end
    end else if (s_axis_tvalid && full_wr && FRAME_FIFO && !DROP_OVERSIZE_FRAME) begin
        // data valid with packet overflow
        // update write pointer
        wr_ptr_gray_reg_n = (wr_ptr_cur_reg) ^ ((wr_ptr_cur_reg) >> 1);
        if (wr_ptr_update_reg == wr_ptr_update_ack_sync2_reg) begin
            // no sync in progress; sync update
            wr_ptr_update_reg_n = !wr_ptr_update_ack_sync2_reg;
        end
    end
    if (s_rst_sync3_reg) begin
        wr_ptr_update_reg_n = 1'b0;
        wr_ptr_gray_reg_n = {ADDR_WIDTH+1{1'b0}};
    end
end

endmodule
