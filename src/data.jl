"""
    DistributedDataContainer(data)

`data` must be compatible with `MLUtils` interface. The returned container is compatible
with `MLUtils` interface and is used to partition the dataset across the available
processes.
"""
struct DistributedDataContainer{D}
  data::D
  idxs::Any
end

function DistributedDataContainer(data)
  total_size = length(data)
  split_across = total_workers()
  size_per_process = Int(ceil(total_size / split_across))

  partitions = collect(Iterators.partition(1:total_size, size_per_process))
  idxs = collect(partitions[local_rank() + 1])

  return DistributedDataContainer(data, idxs)
end

Base.length(ddc::DistributedDataContainer) = length(ddc.idxs)

Base.getindex(ddc::DistributedDataContainer, i) = getindex(ddc.data, ddc.idxs[i])
