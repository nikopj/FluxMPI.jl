# FluxMPI.jl

Distributed Data Parallel Training of Deep Neural Networks

**NOTE**: This package has very little to do with Flux. FWIW it doesn't even depend on it. It can be seamlessly used with [Flux.jl](https://github.com/FluxML/Flux.jl), [Lux.jl](https://github.com/avik-pal/Lux.jl), and pretty much any framework which works with [Optimisers.jl](https://github.com/FluxML/Optimisers.jl)

**WARNING**: I will be changing the name of this package in the near future.

## Installation

Stable release:

```julia
] add FluxMPI
```

Latest development version:

```julia
] add FluxMPI#main
```

## Quick Start

```julia
using CUDA, Optimisers, FluxMPI, Lux, Random, Zygote

# Step 1: Initialize FluxMPI. Not doing this will segfault your code
FluxMPI.Init()
CUDA.allowscalar(false)

# Step 2: Sync Model Parameters
model = Chain(
    Dense(1, 256, tanh),
    Dense(256, 512),
    Dense(512, 256),
    Dense(256, 1)
)
rng = Random.default_rng()
Random.seed!(rng, local_rank())
ps, st = Lux.setup(rng, model) .|> gpu

ps = FluxMPI.synchronize!(ps; root_rank = 0)
st = FluxMPI.synchronize!(st; root_rank = 0)

# It is the user's responsibility to partition the data across the processes
# In this case, we are training on a total of 16 * <np> samples
x = rand(rng, 1, 16) |> gpu
y = x .^ 2

loss(p) = sum(abs2, model(x, p, st)[1] .- y)

# Step 3: Wrap the optimizer in DistributedOptimizer
#         Scale the learning rate by the number of workers (`total_workers()`).
opt = DistributedOptimiser(Optimisers.ADAM(0.001f0))
st_opt = Optimisers.setup(opt, ps)

gs_ = gradient(loss, ps)[1]
Optimisers.update(st_opt, ps, gs_)

t1 = time()

for epoch in 1:100
    global ps, st_opt
    l, back = pullback(loss, ps)
    clean_println("Epoch $epoch: Loss $l")
    gs = back(one(l))[1]
    st_opt, ps = Optimisers.update(st_opt, ps, gs)
end

clean_println(time() - t1)
```

Run the code using `mpiexecjl -n 3 julia --project=. <filename>.jl`.

## Examples

* [Deep Equilibrium Models](https://github.com/SciML/FastDEQ.jl) -- Deep Implicit Neural Networks & Infinite Time Neural ODEs
* [ImageNet Training with Lux.jl](https://github.com/avik-pal/Lux.jl/tree/main/examples/ImageNet)

## Usage Instructions

There are essentially 6 main steps to remember:

1. Initialize FluxMPI (`FluxMPI.Init()`)
2. Sync Model Parameters and States (`FluxMPI.synchronize!(ps; root_rank)`)
3. Dealing with DataLoading. There are two options:
    1. Manually distribute the data across the processes. If all the processes are using the same data, it becomes quite pointless
    2. Use `DistributedDataContainer`. It takes the `data` and splits it evenly across all the processes. The only assumption is that the `data` is compatible with [MLUtils.jl](https://github.com/JuliaML/MLUtils.jl) API. The returned container is compatible with [MLUtils.jl](https://github.com/JuliaML/MLUtils.jl) and [DataLoaders.jl](https://lorenzoh.github.io/DataLoaders.jl/dev/).
4. Use either of the following APIs:
   1. Wrap Optimiser in `DistributedOptimiser`
   2. Add `allreduce_gradients(gs::NamedTuple)` before `Optimisers.update` call **(available from v0.5.3)**
5. Sync the optimizer state across the processes
6. Change logging code to check for `local_rank() == 0`

Finally, start the code using `mpiexecjl -n <np> julia --project=. <filename>.jl`

## API Reference

All functions have dedicated docstrings. Use the help mode in REPL to access them

1. `FluxMPI.Init` (**not exported since name is very common**)
2. `DistributedOptimiser`
3. `allreduce_gradients` (**available from v0.5.3**)
4. `FluxMPI.synchronize!` (**not exported since name is very common**)
5. `DistributedDataContainer`
6. `MPIExtensions` (**none of the functions are exported**)
   1. `FluxMPI.allreduce!`
   2. `FluxMPI.bcast!`
   3. `FluxMPI.reduce!`
   4. `FluxMPI.Iallreduce!`
   5. `FluxMPI.Ibcast!`

## CUDA-aware MPI

### Setup

OpenMPI has extensive instructions on building [CUDA-aware MPI](https://www-lb.open-mpi.org/faq/?category=buildcuda). Next rebuild MPI.jl using these [instructions](https://juliaparallel.org/MPI.jl/stable/configuration/#Using-a-system-provided-MPI)

Additionally, make sure to set `JULIA_CUDA_USE_MEMPOOL=none`.

### Should you use CUDA-aware MPI?

I would recommend **not** using this atm, since `JULIA_CUDA_USE_MEMPOOL=none` will severely slow down your code (*~2-3x* for most workloads I tested). Instead setup `MPI.jl` using you system provided MPI and set `FLUXMPI_DISABLE_CUDAMPI_SUPPORT=true` (this was significantly more efficient for the *20 Million* Parameter models in `FastDEQ.jl`)

## Changelog

### v0.5

#### v0.5.3

* Introduces a new API for gradient synchronization
  * Don't wrap in `DistributedOptimiser`
  * Instead just add a line `allreduce_gradients(gs::NamedTuple)`

#### v0.5.1

* Internal `MPIExtensions` functions renamed
  * `Allreduce!` --> `allreduce!`
  * `Bcast!` --> `bcast!`
  * `Reduce!` --> `reduce!`
* CUDA-unaware MPI bug resolved https://github.com/avik-pal/Lux.jl/issues/18
* Disable CUDA-aware MPI support from `FluxMPI` using `FLUXMPI_DISABLE_CUDAMPI_SUPPORT=true`
* Temporarily re-added dependencies on `MLDataUtils` and `LearnBase` to ensure `DataLoaders.jl` still works -- This will be dropped in a future release

#### v0.5.0

* `DistributedOptimiser` no longer averages the gradients. Instead, the values are summed across the processes. To ensure averaging divide the loss by `total_workers()`
* `rrule`s and `frule`s defined for `local_rank()` and `total_workers` -- they can now be safely used inside loss functions.

### v0.4

* `clean_print` and `clean_println` print the current time even if `FluxMPI` has not been initialized.
* Calling `local_rank` or `total_workers` before `FluxMPI.Init` doesn't lead to a segfault. Rather we throw an error.
* `MLDataUtils` and `LearnBase` dependencies have been dropped (See https://github.com/avik-pal/FluxMPI.jl/issues/17)
* `Zygote` and `Flux` dependencies have been removed
    * No dispatch for `FluxMPI.synchronize!` is now available for `Zygote.Params`. Instead users should be manually broadcasting the function over `Zygote.Params`

### v0.3

* `broadcast_parameters` has been renamed to `FluxMPI.synchronize!` since it synchronize!s a lot more than trainable parameters now.
* DistributedOptimiser is no longer tied with Flux. We can essentially deal with any training as long as it is compatible with [Optimisers.jl](https://github.com/FluxML/Optimisers.jl)
