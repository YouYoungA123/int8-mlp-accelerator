module adder_tree_32(
input signed [15:0] in0,in1,in2,in3,in4,in5,in6,in7,in8,in9,in10,in11,in12,in13,in14,in15,in16,in17,in18,in19,in20,in21,
in22,in23,in24,in25,in26,in27,in28,in29,in30,in31,
output signed [20:0] out);
wire signed [16:0] s1[0:15];
wire signed [17:0] s2[0:7];
wire signed [18:0] s3[0:3];
wire signed [19:0] s4[0:1];
assign s1[0]=in0+in1;
assign s1[1]=in2+in3;
assign s1[2]=in4+in5;
assign s1[3]=in6+in7;
assign s1[4]=in8+in9;
assign s1[5]=in10+in11;
assign s1[6]=in12+in13;
assign s1[7]=in14+in15;
assign s1[8]=in16+in17;
assign s1[9]=in18+in19;
assign s1[10]=in20+in21;
assign s1[11]=in22+in23;
assign s1[12]=in24+in25;
assign s1[13]=in26+in27;
assign s1[14]=in28+in29;
assign s1[15]=in30+in31;
assign s2[0]=s1[0]+s1[1];
assign s2[1]=s1[2]+s1[3];
assign s2[2]=s1[4]+s1[5];
assign s2[3]=s1[6]+s1[7];
assign s2[4]=s1[8]+s1[9];
assign s2[5]=s1[10]+s1[11];
assign s2[6]=s1[12]+s1[13];
assign s2[7]=s1[14]+s1[15];
assign s3[0]=s2[0]+s2[1];
assign s3[1]=s2[2]+s2[3];
assign s3[2]=s2[4]+s2[5];
assign s3[3]=s2[6]+s2[7];
assign s4[0]=s3[0]+s3[1];
assign s4[1]=s3[2]+s3[3];
assign out=s4[0]+s4[1];
endmodule