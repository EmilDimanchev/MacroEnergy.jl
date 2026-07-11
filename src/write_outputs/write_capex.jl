"""
CAPEX outputs — upfront investment cost × new capacity for each component that can have capacity variables and be expanded (edges and storages). """

"""
    write_capex(file_path::AbstractString, system::System, scaling::Float64, discount_rate::Float64; drop_cols::Vector{<:AbstractString}=String[])

Write CAPEX results (upfront investment cost × new capacity) for all expandable
edges and storages in the system to a file.

CAPEX is defined as `investment_cost × new_capacity`. When only
`annualized_investment_cost` is provided (i.e. `investment_cost == 0`), the
upfront cost is back-calculated as:

```
investment_cost = annualized_investment_cost / capital_recovery_factor(wacc, capital_recovery_period)
```

When `wacc` is missing on a component, `discount_rate` is used as the fallback —
consistent with the forward computation in `compute_annualized_costs!`.

No discounting is applied.

# Arguments
- `file_path::AbstractString`: Path to the output file (extension determines format)
- `system::System`: The system containing the assets to analyze
- `scaling::Float64`: Parameter scaling factor; applied as `scaling^2` since CAPEX is a product of a cost and a capacity (each scaled by `scaling`)
- `discount_rate::Float64`: Fallback rate when a component's `wacc` is missing (should match `settings.DiscountRate`)
- `drop_cols::Vector{AbstractString}`: Columns to drop from the DataFrame

# Returns
- `nothing`
"""
function write_capex(
    file_path::AbstractString,
    system::System,
    scaling::Float64=1.0,
    settings::NamedTuple=NamedTuple();
    drop_cols::Vector{<:AbstractString}=String[]
)
    @info "Writing CAPEX results to $file_path"
    capex_results = get_capex(system, scaling, settings)
    write_dataframe(file_path, capex_results, drop_cols)
    return nothing
end

"""
    get_capex(system::System, scaling::Float64, settings::NamedTuple) -> DataFrame

Compute CAPEX (`investment_cost × new_capacity`) for all expandable edges and
storages in the system. Returns a DataFrame with four rows per component: the
total `:capex` plus the decomposed `:capex_de`, `:capex_af` and `:capex_cc`
components (`investment_cost × <c>_cost_perc × new_<c>_capacity`).

`settings` is used to access the discount rate when a component's `wacc` is missing.
"""
function get_capex(system::System, scaling::Float64=1.0, settings::NamedTuple=NamedTuple())
    edges, edge_asset_map = edges_with_capacity_variables(system, return_ids_map=true)
    storages, storage_asset_map = storages_with_capacity_variables(system, return_ids_map=true)
    all_objs = vcat(edges, storages)
    all_maps = merge(edge_asset_map, storage_asset_map)

    isempty(all_objs) && return DataFrame()

    rows = [
        merge(
            (
                commodity      = get_commodity_name(obj),
                zone           = get_zone_name(obj),
                resource_id    = get_resource_id(obj, all_maps),
                component_id   = get_component_id(obj),
                resource_type  = get_type(all_maps[id(obj)]),
                component_type = get_type(obj),
            ),
            (variable = var, value = val * scaling^2),
        )
        for obj in all_objs
        for (var, val) in zip((:capex, :capex_de, :capex_af, :capex_cc), _capex_values(obj, settings))
    ]

    df = DataFrame(rows)
    df[!, (!isa).(eachcol(df), Vector{Missing})]
end

# Return the CAPEX values for a component as `(capex, capex_de, capex_af, capex_cc)`:
#   capex    = investment_cost × new_capacity
#   capex_de = investment_cost × de_cost_perc × new_de_capacity
#   capex_af = investment_cost × af_cost_perc × new_af_capacity
#   capex_cc = investment_cost × cc_cost_perc × new_cc_capacity
# The de/af/cc components use the same upfront `investment_cost` as the total capex
# (following the reference logic `investment_cost × <c>_cost_perc` in edge.jl/storage.jl)
# applied to the corresponding new_<c>_capacity variable.
# If investment_cost == 0 but annualized_investment_cost is set, back-calculate the
# upfront cost from the annualized cost and the capital recovery factor.
# discount_rate is the fallback when wacc is missing, matching compute_annualized_costs!.
# No ITC subsidy or discounting is applied (consistent with the total-capex logic).
function _capex_values(obj::Union{AbstractEdge, AbstractStorage}, settings::NamedTuple)
    (has_capacity(obj) && can_expand(obj)) || return (0.0, 0.0, 0.0, 0.0)
    discount_rate = settings[:DiscountRate]
    # Apply subsidy depending on stage
    de_itc_schedule = [obj.itc_schedule[(obj.de_duration+obj.af_duration)+1:end]; zeros(min((obj.de_duration+obj.af_duration), length(obj.itc_schedule)))]
    af_itc_schedule = [obj.itc_schedule[(obj.af_duration)+1:end]; zeros(min((obj.af_duration), length(obj.itc_schedule)))]

    if settings[:ProjectDevelopment]
        deployment_cost_perc = 1 - de_cost_perc(obj) - af_cost_perc(obj) - cc_cost_perc(obj)
    else
        deployment_cost_perc = 1.0
    end

    if settings[:TechnologyLearning] && learning_type(obj) in settings[:LearningTechnologies]
        
        inv_cost = value(endog_capex_cost(obj))

    elseif !settings[:TechnologyLearning] || !(learning_type(obj) in settings[:LearningTechnologies])
                
        inv_cost = investment_cost(obj)
        if inv_cost == 0.0
            ann_inv_cost = annualized_investment_cost(obj)
            (isnothing(ann_inv_cost) || ann_inv_cost == 0.0) && return (0.0, 0.0, 0.0, 0.0)
            w = ismissing(wacc(obj)) ? discount_rate : wacc(obj)
            inv_cost = ann_inv_cost / capital_recovery_factor(w, capital_recovery_period(obj))
        end
    end

    capex    = (1-obj.itc_schedule[period_index(obj)]) * inv_cost * deployment_cost_perc * Float64(value(new_capacity(obj)))
    
    capex_de = (1-de_itc_schedule[period_index(obj)]) * inv_cost * de_cost_perc(obj) * Float64(value(new_de_capacity(obj)))
    capex_af = (1-af_itc_schedule[period_index(obj)]) * inv_cost * af_cost_perc(obj) * Float64(value(new_af_capacity(obj)))
    capex_cc = (1-obj.itc_schedule[period_index(obj)]) * inv_cost * cc_cost_perc(obj) * Float64(value(new_cc_capacity(obj)))
    


    return (capex, capex_de, capex_af, capex_cc)
end
