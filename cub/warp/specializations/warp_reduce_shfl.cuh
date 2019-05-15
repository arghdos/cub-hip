/******************************************************************************
 * Copyright (c) 2011, Duane Merrill.  All rights reserved.
 * Copyright (c) 2011-2017, NVIDIA CORPORATION.  All rights reserved.
 * 
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *     * Redistributions of source code must retain the above copyright
 *       notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above copyright
 *       notice, this list of conditions and the following disclaimer in the
 *       documentation and/or other materials provided with the distribution.
 *     * Neither the name of the NVIDIA CORPORATION nor the
 *       names of its contributors may be used to endorse or promote products
 *       derived from this software without specific prior written permission.
 * 
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL NVIDIA CORPORATION BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 ******************************************************************************/

/**
 * \file
 * cub::WarpReduceShfl provides SHFL-based variants of parallel reduction of items partitioned across a CUDA thread warp.
 */

#pragma once

#include "../../thread/thread_operators.cuh"
#include "../../util_ptx.cuh"
#include "../../util_type.cuh"
#include "../../util_macro.cuh"
#include "../../util_namespace.cuh"
#include "warp_default_mask.cuh"

/// Optional outer namespace(s)
CUB_NS_PREFIX

/// CUB namespace
namespace cub {


/**
 * \brief WarpReduceShfl provides SHFL-based variants of parallel reduction of items partitioned across a CUDA thread warp.
 *
 * LOGICAL_WARP_THREADS must be a power-of-two
 */
template <
    typename    T,                      ///< Data type being reduced
    int         LOGICAL_WARP_THREADS,   ///< Number of threads per logical warp
    int         PTX_ARCH>               ///< The PTX compute capability for which to to specialize this collective
struct WarpReduceShfl
{
    //---------------------------------------------------------------------
    // Constants and type definitions
    //---------------------------------------------------------------------

    enum
    {
        /// Whether the logical warp size and the PTX warp size coincide
        IS_ARCH_WARP = (LOGICAL_WARP_THREADS == CUB_WARP_THREADS(PTX_ARCH)),

        /// The number of warp reduction steps
        STEPS = Log2<LOGICAL_WARP_THREADS>::VALUE,

        /// Number of logical warps in a PTX warp
        LOGICAL_WARPS = CUB_WARP_THREADS(PTX_ARCH) / LOGICAL_WARP_THREADS,
    };

    template <typename S>
    struct IsInteger
    {
        enum {
            ///Whether the data type is a small (32b or less) integer for which we can use a single SFHL instruction per exchange
            IS_SMALL_UNSIGNED = (Traits<S>::CATEGORY == UNSIGNED_INTEGER) && (sizeof(S) <= sizeof(unsigned int))
        };
    };


    // Creates a mask where the last thread in each logical warp is set
    template <int WARP, int WARPS>
    struct LastLaneMask
    {
	#ifdef __HIP_PLATFORM_NVCC__
        enum {
            BASE_MASK   = 1 << (LOGICAL_WARP_THREADS - 1),
            MASK        = (LastLaneMask<WARP + 1, WARPS>::MASK << LOGICAL_WARP_THREADS) | BASE_MASK,
        };
	#endif

	#ifdef __HIP_PLATFORM_HCC__
        enum uint_64t{
            BASE_MASK   = (long long)1 << (LOGICAL_WARP_THREADS - 1),
            MASK        = ((long long)LastLaneMask<WARP + 1, WARPS>::MASK << LOGICAL_WARP_THREADS) | BASE_MASK,
        };
	#endif
    };

    // Creates a mask where the last thread in each logical warp is set
    template <int WARP>
    struct LastLaneMask<WARP, WARP>
    {
	#ifdef __HIP_PLATFORM_NVCC__
        enum {
            MASK        = 1 << (LOGICAL_WARP_THREADS - 1),
        };
	#endif

	#ifdef __HIP_PLATFORM_HCC__
        enum uint64_t{
            MASK        = (long long)1 << (LOGICAL_WARP_THREADS - 1),
        };
	#endif
    };

    /// Shared memory storage layout type
    typedef NullType TempStorage;


    //---------------------------------------------------------------------
    // Thread fields
    //---------------------------------------------------------------------

    int lane_id;

    int member_mask;

    //---------------------------------------------------------------------
    // Construction
    //---------------------------------------------------------------------

    /// Constructor
    __device__ __forceinline__ WarpReduceShfl(
        TempStorage &/*temp_storage*/)
    :
        lane_id(LaneId()),

        member_mask(IS_ARCH_WARP ?
             DefaultMask() :
             (DefaultMask() >> (warpSize - LOGICAL_WARP_THREADS)) << (LaneId() / LOGICAL_WARP_THREADS))
    {}


    //---------------------------------------------------------------------
    // Reduction steps
    //---------------------------------------------------------------------

    /// Reduction (specialized for summation across uint32 types)
    __device__ __forceinline__ unsigned int ReduceStep(
        unsigned int    input,              ///< [in] Calling thread's input item.
        cub::Sum        /*reduction_op*/,   ///< [in] Binary reduction operator
        int             last_lane,          ///< [in] Index of last lane in segment
        int             offset)             ///< [in] Up-offset to pull from
    {
        unsigned int output;

        // Use predicate set from SHFL to guard against invalid peers
#ifdef __HIP_PLATFORM_NVCC__
        asm volatile(
            "{"
            "  .reg .u32 r0;"
            "  .reg .pred p;"
            "  shfl.down.b32 r0|p, %1, %2, %3;"
            "  @p add.u32 r0, r0, %4;"
            "  mov.u32 %0, r0;"
            "}"
            : "=r"(output) : "r"(input), "r"(offset), "r"(last_lane), "r"(input));
#elif defined(__HIP_PLATFORM_HCC__)
	 unsigned int r0;
	 int lane_id;
	 bool pred = false;
	r0 = __shfl_down((int)input, offset);
	lane_id = (((hipThreadIdx_z * hipBlockDim_x * hipBlockDim_y) + (hipThreadIdx_y * hipBlockDim_x) + hipThreadIdx_x) % warpSize);
	if (offset + lane_id <= last_lane)
            output = r0 + input;
        else
            output = input;
#endif

        return output;
    }


    /// Reduction (specialized for summation across fp32 types)
    __device__ __forceinline__ float ReduceStep(
        float           input,              ///< [in] Calling thread's input item.
        cub::Sum        /*reduction_op*/,   ///< [in] Binary reduction operator
        int             last_lane,          ///< [in] Index of last lane in segment
        int             offset)             ///< [in] Up-offset to pull from
    {
        float output;

        // Use predicate set from SHFL to guard against invalid peers
#ifdef __HIP_PLATFORM_NVCC__
        asm volatile(
            "{"
            "  .reg .f32 r0;"
            "  .reg .pred p;"
            "  shfl.down.b32 r0|p, %1, %2, %3;"
            "  @p add.f32 r0, r0, %4;"
            "  mov.f32 %0, r0;"
            "}"
            : "=f"(output) : "f"(input), "r"(offset), "r"(last_lane), "f"(input));
#elif defined(__HIP_PLATFORM_HCC__)

	 float r0;
         int lane_id;
         bool pred = false;
        r0 = __shfl_down(input, offset);
	lane_id = (((hipThreadIdx_z * hipBlockDim_x * hipBlockDim_y) + (hipThreadIdx_y * hipBlockDim_x) + hipThreadIdx_x) % warpSize);
        if (offset + lane_id <= last_lane)
            output = r0 + input;
        else
            output = input;
#endif

        return output;
    }


    /// Reduction (specialized for summation across unsigned long long types)
    __device__ __forceinline__ unsigned long long ReduceStep(
        unsigned long long  input,              ///< [in] Calling thread's input item.
        cub::Sum            /*reduction_op*/,   ///< [in] Binary reduction operator
        int                 last_lane,          ///< [in] Index of last lane in segment
        int                 offset)             ///< [in] Up-offset to pull from
    {
        unsigned long long output;
#ifdef __HIP_PLATFORM_NVCC__
        asm volatile(
            "{"
            "  .reg .u32 lo;"
            "  .reg .u32 hi;"
            "  .reg .pred p;"
            "  mov.b64 {lo, hi}, %1;"
            "  shfl.down.b32 lo|p, lo, %2, %3;"
            "  shfl.down.b32 hi|p, hi, %2, %3;"
            "  mov.b64 %0, {lo, hi};"
            "  @p add.u64 %0, %0, %1;"
            "}"
            : "=l"(output) : "l"(input), "r"(offset), "r"(last_lane));
#elif defined(__HIP_PLATFORM_HCC__)
	 unsigned int hi , lo;
	int lane_id;
	lo = 0xFFFFFFFF & input;
	hi = 0xFFFFFFFF & (input >> 32);
	lo = __shfl_down((int)lo, offset);
	hi = __shfl_down((int)hi, offset);
	output = ((unsigned long long)hi << 32) | lo;
	lane_id = (((hipThreadIdx_z * hipBlockDim_x * hipBlockDim_y) + (hipThreadIdx_y * hipBlockDim_x) + hipThreadIdx_x) % warpSize) ;
	if (offset + lane_id <= last_lane)
		output = output + input;
	else
		output = input;
#endif

        return output;
    }


    /// Reduction (specialized for summation across long long types)
    __device__ __forceinline__ long long ReduceStep(
        long long           input,              ///< [in] Calling thread's input item.
        cub::Sum            /*reduction_op*/,   ///< [in] Binary reduction operator
        int                 last_lane,          ///< [in] Index of last lane in segment
        int                 offset)             ///< [in] Up-offset to pull from
    {
        long long output;
#ifdef __HIP_PLATFORM_NVCC__
        // Use predicate set from SHFL to guard against invalid peers
        asm volatile(
            "{"
            "  .reg .u32 lo;"
            "  .reg .u32 hi;"
            "  .reg .pred p;"
            "  mov.b64 {lo, hi}, %1;"
            "  shfl.down.b32 lo|p, lo, %2, %3;"
            "  shfl.down.b32 hi|p, hi, %2, %3;"
            "  mov.b64 %0, {lo, hi};"
            "  @p add.s64 %0, %0, %1;"
            "}"
            : "=l"(output) : "l"(input), "r"(offset), "r"(last_lane));
#elif defined(__HIP_PLATFORM_HCC__)
	 unsigned int hi , lo;
        int lane_id;
        lo = 0xFFFFFFFF & input;
        hi = 0xFFFFFFFF & (input >> 32);
        lo = __shfl_down((int)lo, offset);
        hi = __shfl_down((int)hi, offset);
        output = ((long long)hi << 32) | lo;
        lane_id = (((hipThreadIdx_z * hipBlockDim_x * hipBlockDim_y) + (hipThreadIdx_y * hipBlockDim_x) + hipThreadIdx_x) % warpSize) ;
        if (offset + lane_id <= last_lane)
                output = output + input;
        else
                output = input;
#endif

        return output;
    }


    /// Reduction (specialized for summation across double types)
    __device__ __forceinline__ double ReduceStep(
        double              input,              ///< [in] Calling thread's input item.
        cub::Sum            /*reduction_op*/,   ///< [in] Binary reduction operator
        int                 last_lane,          ///< [in] Index of last lane in segment
        int                 offset)             ///< [in] Up-offset to pull from
    {
        double output;

        // Use predicate set from SHFL to guard against invalid peers
#ifdef __HIP_PLATFORM_NVCC__
        asm volatile(
            "{"
            "  .reg .u32 lo;"
            "  .reg .u32 hi;"
            "  .reg .pred p;"
            "  .reg .f64 r0;"
            "  mov.b64 %0, %1;"
            "  mov.b64 {lo, hi}, %1;"
            "  shfl.down.b32 lo|p, lo, %2, %3;"
            "  shfl.down.b32 hi|p, hi, %2, %3;"
            "  mov.b64 r0, {lo, hi};"
            "  @p add.f64 %0, %0, r0;"
            "}"
            : "=d"(output) : "d"(input), "r"(offset), "r"(last_lane));
#elif defined(__HIP_PLATFORM_HCC__)

	union ld
	{
		long long l;
		double d;
	}s;
	s.d = input;
         unsigned int hi, lo;
	int lane_id;
        lo = 0xFFFFFFFF & s.l;
        hi = 0xFFFFFFFF & (s.l >> 32);
        lo = __shfl_down((int)lo,offset);
        hi = __shfl_down((int)hi,offset);
	 long long r0 = 0x0000;
	output = input ;
	r0 = ((r0 | hi)<<32) | lo;
	lane_id = (((hipThreadIdx_z * hipBlockDim_x * hipBlockDim_y) + (hipThreadIdx_y * hipBlockDim_x) + hipThreadIdx_x) % warpSize) ;
	if (offset + lane_id <= last_lane)
	{
		s.l = r0;
		output = output + s.d;
	}
	else
		output = input;
#endif

        return output;
    }


    /// Reduction (specialized for swizzled ReduceByKeyOp<cub::Sum> across KeyValuePair<KeyT, ValueT> types)
    template <typename ValueT, typename KeyT>
    __device__ __forceinline__ KeyValuePair<KeyT, ValueT> ReduceStep(
        KeyValuePair<KeyT, ValueT>                  input,              ///< [in] Calling thread's input item.
        SwizzleScanOp<ReduceByKeyOp<cub::Sum> >     /*reduction_op*/,       ///< [in] Binary reduction operator
        int                                         last_lane,          ///< [in] Index of last lane in segment
        int                                         offset)             ///< [in] Up-offset to pull from
    {
        KeyValuePair<KeyT, ValueT> output;

        KeyT other_key = ShuffleDown(input.key, offset, last_lane, member_mask);
        
        output.key = input.key;
        output.value = ReduceStep(
            input.value, 
            cub::Sum(), 
            last_lane, 
            offset, 
            Int2Type<IsInteger<ValueT>::IS_SMALL_UNSIGNED>());

        if (input.key != other_key)
            output.value = input.value;

        return output;
    }



    /// Reduction (specialized for swizzled ReduceBySegmentOp<cub::Sum> across KeyValuePair<OffsetT, ValueT> types)
    template <typename ValueT, typename OffsetT>
    __device__ __forceinline__ KeyValuePair<OffsetT, ValueT> ReduceStep(
        KeyValuePair<OffsetT, ValueT>                 input,              ///< [in] Calling thread's input item.
        SwizzleScanOp<ReduceBySegmentOp<cub::Sum> >   /*reduction_op*/,   ///< [in] Binary reduction operator
        int                                           last_lane,          ///< [in] Index of last lane in segment
        int                                           offset)             ///< [in] Up-offset to pull from
    {
        KeyValuePair<OffsetT, ValueT> output;

        output.value = ReduceStep(input.value, cub::Sum(), last_lane, offset, Int2Type<IsInteger<ValueT>::IS_SMALL_UNSIGNED>());
        output.key = ReduceStep(input.key, cub::Sum(), last_lane, offset, Int2Type<IsInteger<OffsetT>::IS_SMALL_UNSIGNED>());

        if (input.key > 0)
            output.value = input.value;

        return output;
    }


    /// Reduction step (generic)
    template <typename _T, typename ReductionOp>
    __device__ __forceinline__ _T ReduceStep(
        _T                  input,              ///< [in] Calling thread's input item.
        ReductionOp         reduction_op,       ///< [in] Binary reduction operator
        int                 last_lane,          ///< [in] Index of last lane in segment
        int                 offset)             ///< [in] Up-offset to pull from
    {
        _T output = input;

        _T temp = ShuffleDown(output, offset, last_lane, member_mask);

        // Perform reduction op if valid
        if (offset + lane_id <= last_lane)
            output = reduction_op(input, temp);

        return output;
    }


    /// Reduction step (specialized for small unsigned integers size 32b or less)
    template <typename _T, typename ReductionOp>
    __device__ __forceinline__ _T ReduceStep(
        _T              input,                  ///< [in] Calling thread's input item.
        ReductionOp     reduction_op,           ///< [in] Binary reduction operator
        int             last_lane,              ///< [in] Index of last lane in segment
        int             offset,                 ///< [in] Up-offset to pull from
        Int2Type<true>  /*is_small_unsigned*/)  ///< [in] Marker type indicating whether T is a small unsigned integer
    {
        // Recast as uint32 to take advantage of any specializations
        unsigned int temp = input;//*reinterpret_cast<unsigned int*>(&input);
        temp = ReduceStep(temp, reduction_op, last_lane, offset);
        return static_cast<_T>(temp);//reinterpret_cast<_T&>(temp);
    }


    /// Reduction step (specialized for types other than small unsigned integers size 32b or less)
    template <typename _T, typename ReductionOp>
    __device__ __forceinline__ _T ReduceStep(
        _T              input,                  ///< [in] Calling thread's input item.
        ReductionOp     reduction_op,           ///< [in] Binary reduction operator
        int             last_lane,              ///< [in] Index of last lane in segment
        int             offset,                 ///< [in] Up-offset to pull from
        Int2Type<false> /*is_small_unsigned*/)  ///< [in] Marker type indicating whether T is a small unsigned integer
    {
        return ReduceStep(input, reduction_op, last_lane, offset);
    }


    //---------------------------------------------------------------------
    // Templated inclusive scan iteration
    //---------------------------------------------------------------------

    template <typename ReductionOp, int STEP>
    __device__ __forceinline__ void ReduceStep(
        T&              input,              ///< [in] Calling thread's input item.
        ReductionOp     reduction_op,       ///< [in] Binary reduction operator
        int             last_lane,          ///< [in] Index of last lane in segment
        Int2Type<STEP>  /*step*/)
    {
        input = ReduceStep(input, reduction_op, last_lane, 1 << STEP, Int2Type<IsInteger<T>::IS_SMALL_UNSIGNED>());

        ReduceStep(input, reduction_op, last_lane, Int2Type<STEP + 1>());
    }

    template <typename ReductionOp>
    __device__ __forceinline__ void ReduceStep(
        T&              /*input*/,              ///< [in] Calling thread's input item.
        ReductionOp     /*reduction_op*/,       ///< [in] Binary reduction operator
        int             /*last_lane*/,          ///< [in] Index of last lane in segment
        Int2Type<STEPS> /*step*/)
    {}


    //---------------------------------------------------------------------
    // Reduction operations
    //---------------------------------------------------------------------

    /// Reduction
    template <
        bool            ALL_LANES_VALID,        ///< Whether all lanes in each warp are contributing a valid fold of items
        int             FOLDED_ITEMS_PER_LANE,  ///< Number of items folded into each lane
        typename        ReductionOp>
    __device__ __forceinline__ T Reduce(
        T               input,                  ///< [in] Calling thread's input
        int             folded_items_per_warp,  ///< [in] Total number of valid items folded into each logical warp
        ReductionOp     reduction_op)           ///< [in] Binary reduction operator
    {
        // Get the last thread in the logical warp
        int first_warp_thread   = 0;
        int last_warp_thread    = LOGICAL_WARP_THREADS - 1;
        if (!IS_ARCH_WARP)
        {
            first_warp_thread = lane_id & (~(LOGICAL_WARP_THREADS - 1));
            last_warp_thread |= lane_id;
        }

        // Common case is FOLDED_ITEMS_PER_LANE = 1 (or a multiple of 32)
        int lanes_with_valid_data = (folded_items_per_warp - 1) / FOLDED_ITEMS_PER_LANE;

        // Get the last valid lane
        int last_lane = (ALL_LANES_VALID) ?
            last_warp_thread :
            CUB_MIN(last_warp_thread, first_warp_thread + lanes_with_valid_data);

        T output = input;

//        // Iterate reduction steps
//        #pragma unroll
//        for (int STEP = 0; STEP < STEPS; STEP++)
//        {
//            output = ReduceStep(output, reduction_op, last_lane, 1 << STEP, Int2Type<IsInteger<T>::IS_SMALL_UNSIGNED>());
//        }

        // Template-iterate reduction steps
        ReduceStep(output, reduction_op, last_lane, Int2Type<0>());

        return output;
    }

__device__ int __hip_clzll(unsigned long long x)

{

    int count = 0;

    unsigned long long input = x;

        for (int i = 0; i < 64; i++)

    {

        if ((input & ((unsigned long long)1 << i)) == 0) count++;

        else count = 0;
    }

    return count;

}

    /// Segmented reduction
    template <
        bool            HEAD_SEGMENTED,     ///< Whether flags indicate a segment-head or a segment-tail
        typename        FlagT,
        typename        ReductionOp>
    __device__ __forceinline__ T SegmentedReduce(
        T               input,              ///< [in] Calling thread's input
        FlagT           flag,               ///< [in] Whether or not the current lane is a segment head/tail
        ReductionOp     reduction_op)       ///< [in] Binary reduction operator
    {
        // Get the start flags for each thread in the warp.

	#ifdef __HIP_PLATFORM_NVCC__
	int warp_flags = __ballot(flag);
	#endif

	#ifdef __HIP_PLATFORM_HCC__
	long long warp_flags = __ballot(flag);
	#endif

        if (HEAD_SEGMENTED)
            warp_flags >>= 1;

        // Mask in the last lanes of each logical warp
        warp_flags |= LastLaneMask<1, LOGICAL_WARPS>::MASK;

        // Mask out the bits below the current thread
        warp_flags &= LaneMaskGe();

        // Find the next set flag

	#ifdef __HIP_PLATFORM_NVCC__
        int last_lane = __clz(__brev(warp_flags));
	#endif

	#ifdef __HIP_PLATFORM_HCC__
	int last_lane = __hip_clzll(__brevll(warp_flags));
	#endif

        T output = input;

//        // Iterate reduction steps
//        #pragma unroll
//        for (int STEP = 0; STEP < STEPS; STEP++)
//        {
//            output = ReduceStep(output, reduction_op, last_lane, 1 << STEP, Int2Type<IsInteger<T>::IS_SMALL_UNSIGNED>());
//        }

        // Template-iterate reduction steps
        ReduceStep(output, reduction_op, last_lane, Int2Type<0>());

        return output;
    }
};


}               // CUB namespace
CUB_NS_POSTFIX  // Optional outer namespace(s)
