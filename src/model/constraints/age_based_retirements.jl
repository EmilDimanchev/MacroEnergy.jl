Base.@kwdef mutable struct AgeBasedRetirementConstraint <: PlanningConstraint
    value::Union{Missing,Vector{Float64}} = missing
    constraint_dual::Union{Missing,Vector{Float64}} = missing
    constraint_ref::Union{Missing,JuMPConstraint} = missing
end

function add_model_constraint!(ct::AgeBasedRetirementConstraint, y::Union{AbstractEdge,AbstractStorage}, model::Model, settings::NamedTuple)
    

    curr_period = period_index(y);
    ret_period = retirement_period(y);


    #### All new capacity built up to the retirement period must either retire or be retrofitted in the current period
    if can_retire(y)
        ct.constraint_ref = @constraint(
            model, 
            sum(new_capacity_track(y,k) for k=1:ret_period;init=0) + min_retired_capacity(y) <= sum(retired_capacity_track(y,k) for k=1:curr_period) + sum(retrofitted_capacity_track(y,k) for k=1:curr_period)
        )
    end



    return nothing
end
