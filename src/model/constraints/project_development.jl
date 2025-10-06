Base.@kwdef mutable struct DevelopmentConstraint <: PlanningConstraint
    value::Union{Missing,Vector{Float64}} = missing
    lagrangian_multiplier::Union{Missing,Vector{Float64}} = missing
    constraint_ref::Union{Missing,JuMPConstraint} = missing
end


function add_model_constraint!(ct::DevelopmentConstraint, y::Union{AbstractEdge,AbstractStorage}, model::Model, settings::NamedTuple)

    if settings[:ProjectDevelopment]
        
    
        # if occursin("_transmission_edge", string(y.id)) || occursin("coal", string(y.id)) || occursin("gas", string(y.id)) || occursin("nuclear", string(y.id)) || occursin("wind", string(y.id)) || occursin("solar", string(y.id))
        if occursin("_transmission_edge", string(y.id))
            nothing  # Skip transmission lines
        else
            # println("Adding project development constraints for $(y.id)")
            curr_period = period_index(y)
            prev_period = curr_period - 1
            prev_period_de = curr_period - de_duration(y) + 1
            prev_period_af = curr_period - af_duration(y) + 1
            prev_period_cc = curr_period - cc_duration(y) + 1
            attrition = 0.9

            ct.constraint_ref = @constraint(model, new_capacity_track(y, curr_period) <= cc_capacity_track(y, prev_period))
            
            if curr_period == 1
                # Track cumulative developed capacity
                # Definition and evaluation (DE)
                ct.constraint_ref = @constraint(model, de_capacity_track(y, curr_period) == new_de_capacity_track(y, curr_period))
                # Approvals and funding (AF)
                ct.constraint_ref = @constraint(model, new_af_capacity_track(y, curr_period) <= 0)
                ct.constraint_ref = @constraint(model, af_capacity_track(y, curr_period) == new_af_capacity_track(y, curr_period))
                # Construction and commissioning (CC)
                ct.constraint_ref = @constraint(model, new_cc_capacity_track(y, curr_period) <= 0)
                ct.constraint_ref = @constraint(model, cc_capacity_track(y, curr_period) == new_cc_capacity_track(y, curr_period))
            elseif curr_period >= 2
                # Track cumulative developed capacity
                # Definition and evaluation (DE)
                ct.constraint_ref = @constraint(model, de_capacity_track(y, curr_period) == de_capacity_track(y, prev_period)*attrition + new_de_capacity_track(y, prev_period_de) - new_af_capacity_track(y, curr_period))
                # Approvals and funding (AF)
                ct.constraint_ref = @constraint(model, af_capacity_track(y, curr_period) == af_capacity_track(y, prev_period)*attrition + new_af_capacity_track(y, prev_period_af) - new_cc_capacity_track(y, curr_period))
                # Construction and commissioning (CC)
                ct.constraint_ref = @constraint(model, cc_capacity_track(y, curr_period) == cc_capacity_track(y, prev_period)*attrition + new_cc_capacity_track(y, prev_period_cc) - new_capacity_track(y, curr_period))
                # Projects proceeding to next stage
                # Definition and evaluation (DE)
                ct.constraint_ref = @constraint(model, new_af_capacity_track(y, curr_period) <= de_capacity_track(y, prev_period))
                # Approvals and funding (AF)
                ct.constraint_ref = @constraint(model, new_cc_capacity_track(y, curr_period) <= af_capacity_track(y, prev_period))
                # Construction and commissioning (CC)
            end
        end
    end

    return nothing

end
