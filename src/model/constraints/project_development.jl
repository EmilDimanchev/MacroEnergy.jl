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
            prev_period_af = af_duration(y) > 0 ? curr_period - af_duration(y) + 1 : curr_period
            prev_period_cc = curr_period - cc_duration(y) + 1

            ct.constraint_ref = @constraint(model, new_capacity_track(y, curr_period) <= cc_capacity_track(y, prev_period))
            ct.constraint_ref = @constraint(model, new_cc_capacity_track(y, curr_period) <= af_capacity_track(y, prev_period))
            ct.constraint_ref = @constraint(model, new_af_capacity_track(y, curr_period) <= de_capacity_track(y, prev_period))

            model[:DECapacity] = AffExpr(0.0)
            model[:AFCapacity] = AffExpr(0.0)
            model[:CCCapacity] = AffExpr(0.0)

            if curr_period >= 2
                # Add previous periods' capacity 
                add_to_expression!(model[:DECapacity], de_capacity_track(y, prev_period), 1.0)
                add_to_expression!(model[:AFCapacity], af_capacity_track(y, prev_period), 1.0)
                add_to_expression!(model[:CCCapacity], cc_capacity_track(y, prev_period), 1.0)

                # Subtract used capacity
                if af_duration(y) > 0
                    add_to_expression!(model[:DECapacity], new_af_capacity_track(y, curr_period), -1.0)
                else
                    add_to_expression!(model[:DECapacity], new_cc_capacity_track(y, curr_period), -1.0)
                end
                add_to_expression!(model[:AFCapacity], new_cc_capacity_track(y, curr_period), -1.0)
                add_to_expression!(model[:CCCapacity], new_capacity_track(y, curr_period), -1.0)
            end

            if curr_period >= de_duration(y) 
                add_to_expression!(model[:DECapacity], new_de_capacity_track(y, prev_period_de), 1.0)
            end                 
            if curr_period >= af_duration(y) 
                add_to_expression!(model[:AFCapacity], new_af_capacity_track(y, prev_period_af), 1.0)
            end                 
            if curr_period >= cc_duration(y) 
                add_to_expression!(model[:CCCapacity], new_cc_capacity_track(y, prev_period_cc), 1.0)
            end                 

            ct.constraint_ref = @constraint(model, de_capacity_track(y, curr_period) == model[:DECapacity])
            if af_duration(y) > 0
                ct.constraint_ref = @constraint(model, af_capacity_track(y, curr_period) == model[:AFCapacity])
            else
                ct.constraint_ref = @constraint(model, af_capacity_track(y, curr_period) == model[:DECapacity])
            end
            ct.constraint_ref = @constraint(model, cc_capacity_track(y, curr_period) == model[:CCCapacity])
        
        end
    end

    return nothing

end
