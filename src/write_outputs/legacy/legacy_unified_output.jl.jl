# Function to collect the results from a system and write them to a CSV file
"""
    write_results(file_path::AbstractString, system::System, model::Model, settings::NamedTuple)

Collects all the results as a `DataFrame` and then writes them to disk after the optimization is performed. 

# Arguments
- `file_path::AbstractString`: full path of the file to export. 
- `system::System`: The system object containing the case inputs.
- `model::Model`: The model being optimized.
- `settings::NamedTuple`: The settings for the system, including output configurations.

# Returns

# Example
```julia
write_results(case_path, system, model, settings, ext=".csv") # CSV
write_results(case_path, system, model, settings, ext=".csv.gz")  # GZIP
write_results(case_path, system, model, settings, ext=".parquet") # PARQUET
```
"""
function write_results(file_path::AbstractString, system::System, model::Model, settings::NamedTuple; ext::AbstractString=".csv.gz")
    @info "Writing results to $file_path"

    # Prepare output data
    tables, table_names = collect_results(system, model, settings)

    for (table, table_name) in zip(tables, table_names)
        table.case_name .= coalesce.(table.case_name, basename(system.data_dirpath))
        
        # Check if the table has a year column before trying to fill it
        if hasproperty(table, :year)
            table.year .= coalesce.(table.year, year(now()))
        end
        
        write_dataframe(file_path * "_" * string(table_name) * ext, table)
    end
end

# Function to collect all the outputs from a system and return them as a DataFrame
"""
    collect_results(system::System, model::Model, settings::NamedTuple, scaling::Float64=1.0)

Returns a `DataFrame` with all the results after the optimization is performed. 

# Arguments
- `system::System`: The system object containing the case inputs.
- `model::Model`: The model being optimized.
- `settings::NamedTuple`: The settings for the system, including output configurations.
- `scaling::Float64`: The scaling factor for the results.
# Returns
- `DataFrame`: A `DataFrame containing all the outputs from a system.

# Example
```julia
collect_results(system, model)
198534×12 DataFrame
    Row │ case_name  commodity    commodity_subtype  zone        resource_id                component_id                       type              variable  segment  time   value
        │ Missing    Symbol       Symbol             Symbol      Symbol                     Symbol                             Symbol            Symbol    Int64    Int64  Float64
────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
      1 │   missing  Biomass      flow               bioherb_SE  SE_BECCS_Electricity_Herb  SE_BECCS_Electricity_Herb_biomas…  BECCSElectricity  flow            1      1  0.0
      2 │   missing  Biomass      flow               bioherb_SE  SE_BECCS_Electricity_Herb  SE_BECCS_Electricity_Herb_biomas…  BECCSElectricity  flow            1      2  0.0
      3 │   missing  Biomass      flow               bioherb_SE  SE_BECCS_Electricity_Herb  SE_BECCS_Electricity_Herb_biomas…  BECCSElectricity  flow            1      3  0.0
      ...
```
"""
function collect_results(system::System, model::Model, settings::NamedTuple, scaling::Float64=1.0)
    edges, edge_asset_map = get_edges(system, return_ids_map=true)

    # capacity variables 
    field_list = (capacity, new_capacity, retired_capacity)
    edges_with_capacity = edges_with_capacity_variables(edges)
    edges_with_capacity_asset_map = filter(edge -> edge[1] in id.(edges_with_capacity), edge_asset_map)
    ecap = get_optimal_vars(edges_with_capacity, field_list, scaling, edges_with_capacity_asset_map)

    ## time series
    # edge flow
    eflow = get_optimal_vars_timeseries(edges, flow, scaling, edge_asset_map)

    # non_served_demand
    nsd = get_optimal_vars_timeseries(system.locations, non_served_demand, scaling, edge_asset_map)

    # storage storage_level
    storages, storage_asset_map = get_storage(system, return_ids_map=true)
    storlevel = get_optimal_vars_timeseries(storages, storage_level, scaling, storage_asset_map)

    # costs
    create_discounted_cost_expressions!(model, system, settings)

    compute_undiscounted_costs!(model, system, settings)

    discounted_costs = prepare_discounted_costs(model, scaling)

    undiscounted_costs = prepare_undiscounted_costs(model, scaling)

    tables = [ecap, eflow, nsd, storlevel, discounted_costs,undiscounted_costs]
    table_names = [:capacity, :flow, :non_served_demand, :storage_level, :discounted_costs, :undiscounted_costs]

    return tables, table_names
end

## Helper functions to extract optimal values of fields from MacroObjects ##
# The following functions are used to extract the values after the model has been solved
# from a list of MacroObjects (e.g., edges, and storage) and a list of fields (e.g., capacity, new_capacity, retired_capacity)
#   e.g.: get_optimal_vars(edges, (capacity, new_capacity, retired_capacity))
get_optimal_vars(objs::Vector{T}, field::Function, scaling::Float64=1.0, obj_asset_map::Dict{Symbol,Base.RefValue{<:AbstractAsset}}=Dict{Symbol,Base.RefValue{<:AbstractAsset}}()) where {T<:Union{AbstractEdge,Storage}} =
    get_optimal_vars(objs, (field,), scaling, obj_asset_map)
function get_optimal_vars(objs::Vector{T}, field_list::Tuple, scaling::Float64=1.0, obj_asset_map::Dict{Symbol,Base.RefValue{<:AbstractAsset}}=Dict{Symbol,Base.RefValue{<:AbstractAsset}}()) where {T<:Union{AbstractEdge,Storage}}
    # the obj_asset_map is used to map the asset component (e.g., natgas_1_natgas_edge, natgas_2_natgas_edge, natgas_1_elec_edge) to the actual asset id (e.g., natgas_1)
    total_rows = length(objs) * length(field_list)
    if isempty(obj_asset_map)
        return DataFrame(
            case_name = fill(missing, total_rows),
            commodity = [get_commodity_name(obj) for obj in objs for f in field_list],
            commodity_subtype = [get_commodity_subtype(f) for obj in objs for f in field_list],
            zone = [get_zone_name(obj) for obj in objs for f in field_list],
            resource_id = [get_component_id(obj) for obj in objs for f in field_list],
            component_id = [get_component_id(obj) for obj in objs for f in field_list],
            type = [get_type(obj) for obj in objs for f in field_list],
            variable = [Symbol(f) for obj in objs for f in field_list],
            year = fill(missing, total_rows),
            value = [Float64(value(f(obj))) * scaling for obj in objs for f in field_list]
        )
    else
        return DataFrame(
            case_name = fill(missing, total_rows),
            commodity = [get_commodity_name(obj) for obj in objs for f in field_list],
            commodity_subtype = [get_commodity_subtype(f) for obj in objs for f in field_list],
            zone = [get_zone_name(obj) for obj in objs for f in field_list],
            resource_id = [get_resource_id(obj, obj_asset_map) for obj in objs for f in field_list],
            component_id = [get_component_id(obj) for obj in objs for f in field_list],
            type = [get_type(obj_asset_map[id(obj)]) for obj in objs for f in field_list],
            variable = [Symbol(f) for obj in objs for f in field_list],
            year = fill(missing, total_rows),
            value = [Float64(value(f(obj))) * scaling for obj in objs for f in field_list]
        )
    end
end

## Helper functions to extract the optimal values of given fields from a list of MacroObjects at different time intervals ##
# e.g., get_optimal_vars_timeseries(edges, flow)

function get_optimal_vars_timeseries(
    objs::Vector{T},
    field_list::Tuple,
    scaling::Float64=1.0,
    obj_asset_map::Dict{Symbol,Base.RefValue{<:AbstractAsset}}=Dict{Symbol,Base.RefValue{<:AbstractAsset}}()
) where {T<:Union{AbstractEdge,Storage,Node,Location}}
    reduce(vcat, [get_optimal_vars_timeseries(o, field_list, scaling, obj_asset_map) for o in objs if !isa(o, Location)]) # filter out locations
end

function get_optimal_vars_timeseries(
    objs::Vector{T},
    f::Function,
    scaling::Float64=1.0,
    obj_asset_map::Dict{Symbol,Base.RefValue{<:AbstractAsset}}=Dict{Symbol,Base.RefValue{<:AbstractAsset}}()
) where {T<:Union{AbstractEdge,Storage,Node,Location}}
    reduce(vcat, [get_optimal_vars_timeseries(o, f, scaling, obj_asset_map) for o in objs if !isa(o, Location)])
end

function get_optimal_vars_timeseries(
    obj::T,
    field_list::Tuple,
    scaling::Float64=1.0,
    obj_asset_map::Dict{Symbol,Base.RefValue{<:AbstractAsset}}=Dict{Symbol,Base.RefValue{<:AbstractAsset}}()
) where {T<:Union{AbstractEdge,Storage,Node}}
    reduce(vcat, [get_optimal_vars_timeseries(obj, f, scaling, obj_asset_map) for f in field_list])
end

function get_optimal_vars_timeseries(
    obj::T,
    f::Function,
    scaling::Float64=1.0,
    obj_asset_map::Dict{Symbol,Base.RefValue{<:AbstractAsset}}=Dict{Symbol,Base.RefValue{<:AbstractAsset}}()
) where {T<:Union{AbstractEdge,Storage,Node}}
    time_axis = time_interval(obj)
    # check if the time series is piecewise linear approximation with segments
    has_segments = ndims(f(obj)) > 1 # a matrix (segments, time)
    num_segments = has_segments ? size(f(obj), 1) : 1
    total_rows = num_segments * length(time_axis)
    
    if isempty(obj_asset_map)
        return DataFrame(
            case_name = fill(missing, total_rows),
            commodity = Symbol[get_commodity_name(obj) for s in 1:num_segments for t in time_axis],
            commodity_subtype = Symbol[get_commodity_subtype(f) for s in 1:num_segments for t in time_axis],
            zone = Symbol[get_zone_name(obj) for s in 1:num_segments for t in time_axis],
            resource_id = Symbol[get_component_id(obj) for s in 1:num_segments for t in time_axis],  # component id is same as resource id
            component_id = Symbol[get_component_id(obj) for s in 1:num_segments for t in time_axis],
            type = Symbol[get_type(obj) for s in 1:num_segments for t in time_axis],
            variable = Symbol[Symbol(f) for s in 1:num_segments for t in time_axis],
            year = fill(missing, total_rows),
            segment = Int[s for s in 1:num_segments for t in time_axis],
            time = Int[t for s in 1:num_segments for t in time_axis],
            value = Float64[has_segments ? value(f(obj, s, t)) * scaling : value(f(obj, t)) * scaling for s in 1:num_segments for t in time_axis]
        )
    else
        return DataFrame(
            case_name = fill(missing, total_rows),
            commodity = Symbol[get_commodity_name(obj) for s in 1:num_segments for t in time_axis],
            commodity_subtype = Symbol[get_commodity_subtype(f) for s in 1:num_segments for t in time_axis],
            zone = Symbol[get_zone_name(obj) for s in 1:num_segments for t in time_axis],
            resource_id = Symbol[isa(obj, Node) ? get_resource_id(obj) : get_resource_id(obj, obj_asset_map) for s in 1:num_segments for t in time_axis],
            component_id = Symbol[get_component_id(obj) for s in 1:num_segments for t in time_axis],
            type = Symbol[isa(obj, Node) ? get_type(obj) : get_type(obj_asset_map[id(obj)]) for s in 1:num_segments for t in time_axis],
            variable = Symbol[Symbol(f) for s in 1:num_segments for t in time_axis],
            year = fill(missing, total_rows),
            segment = Int[s for s in 1:num_segments for t in time_axis],
            time = Int[t for s in 1:num_segments for t in time_axis],
            value = Float64[has_segments ? value(f(obj, s, t)) * scaling : value(f(obj, t)) * scaling for s in 1:num_segments for t in time_axis]
        )
    end
end
