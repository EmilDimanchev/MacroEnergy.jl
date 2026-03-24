Base.@kwdef mutable struct MaxCapacityGrowthConstraint <: PlanningConstraint
    value::Union{Missing,Vector{Float64}} = missing
    lagrangian_multiplier::Union{Missing,Vector{Float64}} = missing
    constraint_ref::Union{Missing,JuMPConstraint} = missing
end


function add_model_constraint!(ct::MaxCapacityGrowthConstraint, y::Union{AbstractEdge,AbstractStorage}, model::Model, settings::NamedTuple)

    # Exclude transmission
    if settings[:DeploymentInertia]

        curr_stage = period_index(y)
        prev_stage = curr_stage - 1

        # Limit rate of increase
        if curr_stage >= 2
            ct.constraint_ref = @constraint(model, new_capacity_track(y,curr_stage) <= max_new_capacity_init(y) + (1+cagr(y))*new_capacity_track(y, prev_stage))
        end

        # Limit rate of decrease
        if curr_stage >= 2
            ct.constraint_ref = @constraint(model, new_capacity_track(y,curr_stage) >= (1-cadr(y))*new_capacity_track(y, prev_stage) - max_new_capacity_init(y))
        end

    end

    return nothing

end