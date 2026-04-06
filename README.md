# RTL Design of a TPU-Inspired Systolic Array Accelerator for High-Performance Matrix Computation with Diagonal Dataflow
This project implements an NxN systolic array-based matrix multiplication accelerator using SystemVerilog. The design leverages parallel multiply-accumulate (MAC) operations with diagonal dataflow to achieve high throughput. It includes a controller FSM, BRAM-based memory, and a scalable architecture suitable for FPGA deployment

## key features
Parameterized NxN architecture <br>
Diagonal (skewed) data feeding <br>
FSM-based control (IDLE → RUN → DONE)<br>
Parallel MAC computation using DSPs<br>
BRAM-based memory integration <br>
Fully pipelined design <br>

## Architecture overview and data flow 
### Top level data flow 
![top_level_dia](/docs/diagrams/top.jpeg)


- The **Controller (FSM)** manages the computation flow and generates control signals (`clear_acc`, `en`, `cycle`).
- The **A_mem and B_mem (ROMs)** store input matrices and provide data (`A_data_out`, `B_data_out`).
- The **Diagonal Feeder Logic** aligns data using cycle-based indexing for correct timing.
- The **Systolic Array (NxN grid)** performs parallel MAC operations.
- The final output is produced as **result[N][N]**.

### Systolic array architecture 
![sys_arr_img](/docs/diagrams/sys.jpeg)
![sys_arr_img](/docs/diagrams/sys_1.jpeg)


### Controller module design 
![controller_img](/docs/diagrams/controller.jpeg)

### Design of the processing element
![pe_img](/docs/diagrams/pe.jpeg)

















