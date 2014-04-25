 module pearl #(
	parameter DWIDTH = 16
 ) (
	input clk,
   input clk_ena,
	input reset,
	input [DWIDTH-1:0] i_data1,
	input [DWIDTH-1:0] i_data2,
	output [DWIDTH-1:0] o_data
 );
    wire [DWIDTH-1:0] anded_data;
    assign anded_data = i_data1 & i_data2;
 
	reg [DWIDTH-1:0] r_data;
	always@(posedge clk or posedge reset) begin
		if(reset) begin
			r_data <= {(DWIDTH) {1'b0}};
		end else if (clk_ena) begin
			r_data <= anded_data;
		end else begin
         //Not enabled, maintain state
			r_data <= r_data;
		end
	end
	
	assign o_data = r_data;
 
 endmodule
 
