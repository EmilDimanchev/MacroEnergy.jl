Base.@kwdef mutable struct DeploymentInertiaConstraint <: PlanningConstraint
    value::Union{Missing,Vector{Float64}} = missing
    constraint_dual::Union{Missing,Vector{Float64}} = missing
    constraint_ref::Union{Missing,JuMPConstraint} = missing
end

function add_model_constraint!(ct::DeploymentInertiaConstraint, system::System, model::Model, settings::NamedTuple)
    # @info "Adding deployment inertia constraints for period $(period_index(system))"
    p_idx = period_index(system)
    scaling_factor = settings.ParameterScaling ? Float64(settings.ParameterScalingFactor) : 1.0
    if p_idx == 1
        # CAGR
        ct.constraint_ref = @constraint(model, [t in settings[:TechsWithInertia]], model[:eDeploymentGrowth][t, p_idx] <= settings[:InertiaInitMW][Symbol(t)] * (1 + settings[:InertiaInitialGrowthRate][Symbol(t)]) / scaling_factor)
        # CADR
        ct.constraint_ref = @constraint(model, [t in settings[:TechsWithInertia]], model[:eDeploymentDecline][t, p_idx] >= settings[:InertiaInitMW][Symbol(t)] * (1 - settings[:InertiaInitialDeclineRate][Symbol(t)]) / scaling_factor)
    elseif p_idx > 1
        # CAGR
        ct.constraint_ref = @constraint(
            model,
            [t in settings[:TechsWithInertia]],
            model[:eDeploymentGrowth][t, p_idx] <= settings[:InertiaMinMW][Symbol(t)]/scaling_factor
        )
        # CADR
        ct.constraint_ref = @constraint(
            model,
            [t in settings[:TechsWithInertia]],
            model[:eDeploymentDecline][t, p_idx] >= -settings[:InertiaMinMW][Symbol(t)]/scaling_factor
        )
    end

    return nothing
end