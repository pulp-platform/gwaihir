#ifndef SURYA_WORKLOAD_H
#define SURYA_WORKLOAD_H

#include "task0_matrix_a.h"
#include "task0_matrix_b.h"
#include "task0_matrix_c.h"
#include "task0_mx_scale.h"

#define NUM_TASKS 1
#define SURYA_HW_CIM_INNER 32
#define SURYA_HW_CIM_OUTER 8
#define SURYA_HW_N_ACCUM 32
#define SURYA_HW_N_CIM 4
#define SURYA_HW_OPTIMAL_BW 1
#define TASK0_A_PTR task0_matrix_a
#define TASK0_B_PTR task0_matrix_b
#define TASK0_C_PTR task0_matrix_c_out
#define TASK0_C_INIT_PTR 0
#define TASK0_NQ_PTR 0
#define TASK0_PACE_PTR 0
#define TASK0_PACE_INV_PTR 0
#define TASK0_PACE_EPS 0
#define TASK0_PACE_EPS_CONST 0
#define TASK0_MX_SCALE_PTR task0_mx_scale
#define TASK0_MX_BLOCK_SIZE 32
#define TASK0_MX_OUT_INT8 0
#define TASK0_MX_OUT_SCALE_PTR 0
#define TASK0_MX_OUT_SCALE_SIZE 0
#define TASK0_M 32
#define TASK0_N 256
#define TASK0_P 32
#define TASK0_OP_MODE 3
#define TASK0_NORM_MODE 2
#define TASK0_ACCUM_INIT_MODE 0
#define TASK0_IS_DEPTHWISE 0
#define TASK0_IS_POINTWISE 0
#define TASK0_DW_OUTPUT 0
#define TASK0_DW_PAD 0
#define TASK0_DW_STRIDE 1
#define TASK0_DW_H_IN 0
#define TASK0_DW_W_IN 0
#define TASK0_NQ_DIM 0
#define TASK0_A_SIGNED 1
#define TASK0_B_SIGNED 1
#define TASK0_RELU 0
#define TASK0_OUT_UNSIGNED 0
#define TASK0_FORCE_RR_PRIORITY 0
#define TASK0_COMPUTE 1
#define TASK0_STREAMOUT 1
#define TASK0_ACCUM_CONTINUE 0
#define TASK0_REUSE_CIM 0
#define TASK0_CIM_CONTEXT 0
#define TASK0_PREFETCH 0
#define TASK0_DISABLE_ZIGZAG 0
#define TASK0_DISABLE_WEIGHT_REUSE 0
#define TASK0_SOFT_CLEAR_STATE 0
#define TASK0_C_GOLDEN task0_matrix_c
#define TASK0_C_SIZE 2048
#define TASK0_C_BUF_SIZE 2048
#define TASK0_HAS_NORMQUANT 0
#define TASK0_CHECK_ACCUM 0

#define SURYA_TASKS(APPLY) \
    APPLY(0)

#endif /* SURYA_WORKLOAD_H */
