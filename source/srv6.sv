`default_nettype none

module srv6 (
	     input wire 	clk,
	     input wire 	reset,
	     input wire [511:0] din,
	     input wire 	valid,
	     output reg [511:0] dout,
	     output reg 	we,
	     // packet buffer
	     output reg [511:0] fifo_d,
	     output reg 	fifo_we,
	     input wire [511:0] fifo_q,
	     output reg 	fifo_rd
);

   reg [3:0] 			 version;
   reg [7:0] 			 traffic_class;
   reg [19:0] 			 flow_label;
   reg [15:0] 			 payload_length;
   reg [7:0] 			 next_header;
   reg [7:0] 			 hop_limit;
   reg [127:0] 			 source_address;
   reg [127:0] 			 destination_address;

   reg [7:0] 			 srh_next_header;
   reg [7:0] 			 srh_hdr_ext_len;
   reg [7:0] 			 srh_routing_type;
   reg [7:0] 			 srh_segment_left;
   reg [7:0] 			 srh_last_entry;
   reg [7:0] 			 srh_flags;
   reg [15:0] 			 srh_tag;
   reg [127:0] 			 last_segment;
   reg [127:0] 			 active_segment;

   reg [7:0] 			 state;
   reg [7:0] 			 segment_ptr;
   reg [15:0] 			 recv_bytes;
   reg [15:0] 			 send_bytes;
   
   localparam IDLE                = 8'd0;
   localparam RECV_ACTIVE_SEGMENT = 8'd1;
   localparam SEND_HEADER         = 8'd3;
   localparam SEND_DATA           = 8'd4;

   always @(posedge clk) begin
      case(state)
	IDLE: begin
	   we <= 1'b0;
	   fifo_we <= 1'b0;
	   recv_bytes <= 15'd0;
	   if(valid == 1'b1) begin
	      version             <= din[511:508];
	      traffic_class       <= din[507:500];
	      flow_label          <= din[499:480];
	      payload_length      <= din[479:464];
	      next_header         <= din[463:456];
	      hop_limit           <= din[455:448];
	      source_address      <= din[447:320];
	      destination_address <= din[319:192]; // or active segment

	      srh_next_header  <= din[191:184];
	      srh_hdr_ext_len  <= din[183:176];
	      srh_routing_type <= din[175:168];
	      srh_segment_left <= din[167:160];
	      srh_last_entry   <= din[159:152];
	      srh_flags        <= din[151:144];
	      srh_tag          <= din[143:128];
	      last_segment     <= din[127:0];
	      
	      if (din[463:456] == 43) begin // SR header exists (next_header == 43)
		 segment_ptr      <= din[167:160] - 1;
		 state <= RECV_ACTIVE_SEGMENT;
		 fifo_rd <= 1'b0;
	      end else begin
		 state <= SEND_HEADER;
		 fifo_rd <= 1'b1; // available fifo data at next next state
	      end
	      recv_bytes <= 64;
	   end else begin // if (valid == 1'b1)
	      fifo_rd <= 1'b0;
	   end
	end // case: IDLE

	RECV_ACTIVE_SEGMENT: begin
	   we <= 1'b0; // not to send

	   // preserve received data
	   if(recv_bytes < payload_length) begin
	      recv_bytes <= recv_bytes + 64;
	      fifo_we <= 1'b1;
	      fifo_d <= din;
	   end else begin
	      fifo_we <= 1'b0;
	   end

	   // get destination address
	   if (srh_segment_left == 1) begin
	      destination_address <= last_segment;
	      srh_segment_left <= srh_segment_left - 1;
	      state <= SEND_HEADER;
	      fifo_rd <= 1'b1; // available fifo data at next next state
	   end else if (srh_segment_left > 1 && segment_ptr < 4) begin
	      srh_segment_left <= srh_segment_left - 1;
	      state <= SEND_HEADER;
	      fifo_rd <= 1'b1; // available fifo data at next next state
	      if(segment_ptr == 0)
		destination_address <= din[511:384];
	      else if(segment_ptr == 1)
		destination_address <= din[383:256];
	      else if(segment_ptr == 2)
		destination_address <= din[255:128];
	      else if(segment_ptr == 3)
		destination_address <= din[127:0];
	   end else begin // if (srh_segment_left > 1 && segment_ptr < 4)
	      segment_ptr <= segment_ptr - 4;
	      fifo_rd <= 1'b0;
	   end // else: !if(srh_segment_left > 1 && segment_ptr < 4)
	   
	end // case: RECV_ACTIVE_SEGMENT

	SEND_HEADER: begin
	   send_bytes <= 64;
	   we <= 1'b1; // send data
	   
	   dout[511:508] <= version;
	   dout[507:500] <= traffic_class;
	   dout[499:480] <= flow_label;
	   dout[479:464] <= payload_length;
	   dout[463:456] <= next_header;
	   dout[455:448] <= hop_limit;
	   dout[447:320] <= source_address;
	   dout[319:192] <= destination_address;

	   dout[191:184] <= srh_next_header;
	   dout[183:176] <= srh_hdr_ext_len;
	   dout[175:168] <= srh_routing_type;
	   dout[167:160] <= srh_segment_left;
	   dout[159:152] <= srh_last_entry;
	   dout[151:144] <= srh_flags;
	   dout[143:128] <= srh_tag;
	   dout[127:0]   <= last_segment;

	   if(recv_bytes < payload_length) begin
	      recv_bytes <= recv_bytes + 64;
	      fifo_we <= 1'b1;
	      fifo_d <= din;
	   end else begin
	      fifo_we <= 1'b0;
	   end
	   fifo_rd <= 1'b1;

	   state <= SEND_DATA;
	end

	SEND_DATA: begin
	   
	   // preserve received data
	   if(recv_bytes < payload_length) begin
	      recv_bytes <= recv_bytes + 64;
	      fifo_we <= 1'b1;
	      fifo_d <= din;
	   end else begin
	      fifo_we <= 1'b0;
	   end

	   // prepare next next data
	   if(send_bytes + 128 < payload_length) begin
	      fifo_rd <= 1'b1;
	   end else begin
	     fifo_rd <= 1'b0;
	   end

	   if(send_bytes < payload_length) begin
	      we <= 1'b1; // send data
	      dout <= fifo_q;
	      send_bytes <= send_bytes + 64;
	   end else begin
	      we <= 1'b0;
	      state <= IDLE;
	   end
	   
	end // case: SEND_DATA

	default: begin
	  state <= IDLE;
	end
	
      endcase
   end

endmodule // srv6
   

`default_nettype none
