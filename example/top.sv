module top #(
	parameter DWIDTH = 16
) (
	input clk,
	input reset,

	input [DWIDTH-1:0] i_data1,
	input i_data1_valid,
	output i_data1_stop,

	input [DWIDTH-1:0] i_data2,
	input i_data2_valid,
	output i_data2_stop,
	
	output [DWIDTH-1:0] o_data,
	output o_data_valid,
	input o_data_stop
);

	li_link #(.WIDTH(DWIDTH)) i_data1_link();
    assign i_data1_link.valid = i_data1_valid;
    assign i_data1_link.data = i_data1;
    assign i_data1_stop = i_data1_link.stop;

	li_link #(.WIDTH(DWIDTH)) i_data2_link();
    assign i_data2_link.valid = i_data2_valid;
    assign i_data2_link.data = i_data2;
    assign i_data2_stop = i_data2_link.stop;

	li_link #(.WIDTH(DWIDTH)) o_data_link();
    assign o_data_valid = o_data_link.valid;
    assign o_data = o_data_link.data;
    assign o_data_link.stop = o_data_stop;

	pearl_wrap #(.DWIDTH(DWIDTH)) pearl_wrap_inst (
        .clk(clk),
        .reset(reset),
        .i_data1_link(i_data1_link),
		  .i_data2_link(i_data2_link),
        .o_data_link(o_data_link)
    );


endmodule
