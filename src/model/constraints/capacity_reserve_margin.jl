Base.@kwdef mutable struct CapacityReserveMarginConstraint <: PlanningConstraint
    value::Union{Missing,Vector{Float64}} = missing
    constraint_dual::Union{Missing,Vector{Float64}} = missing
    constraint_ref::Union{Missing,JuMPConstraint} = missing
end

function add_model_constraint!(ct::CapacityReserveMarginConstraint, system::System, model::Model)
    
    # Get zones and period index from the expression
    crm_zones = axes(model[:eCapacityReserveMargin])[1]
    p_idx = period_index(system)
    
    ct.constraint_ref = @constraint(
            model,
            [k in crm_zones],
            model[:eCapacityReserveMargin][k, p_idx] >= 0.0
        )

    return nothing
end