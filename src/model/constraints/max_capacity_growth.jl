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

    add_energy_inertia_constraints!(system, model, settings, scaling_factor)

    return nothing
end

"""
    add_energy_inertia_constraints!(system, model, settings, scaling_factor)

Deployment inertia on storage energy capacity (MWh). Storage components share their
category with the power capacity (e.g. `battery`) and its MW settings, which are
converted to MWh with the components' `InertiaInitialDuration`. Constraints are only
added for categories that have storage in this period.
"""
function add_energy_inertia_constraints!(system::System, model::Model, settings::NamedTuple, scaling_factor::Float64)
    p_idx = period_index(system)

    durations = Dict{String,Vector{Float64}}()
    for g in get_storages(system)
        category = Inertia_category(g)
        (!isnothing(category) && category ∈ settings[:TechsWithInertia]) || continue
        push!(get!(durations, category, Float64[]), InertiaInitialDuration(g))
    end

    for (t, ds) in durations
        length(unique(ds)) == 1 || error("Deployment inertia: all storage in category '$t' must have the same InertiaInitialDuration, found $(sort(unique(ds)))")
        duration = first(ds)
        tech = Symbol(t)
        if p_idx == 1
            @constraint(model, model[:eDeploymentGrowthEnergy][t, p_idx] <= settings[:InertiaInitMW][tech] * duration * (1 + settings[:InertiaInitialGrowthRate][tech]) / scaling_factor)
            @constraint(model, model[:eDeploymentDeclineEnergy][t, p_idx] >= settings[:InertiaInitMW][tech] * duration * (1 - settings[:InertiaInitialDeclineRate][tech]) / scaling_factor)
        else
            @constraint(model, model[:eDeploymentGrowthEnergy][t, p_idx] <= settings[:InertiaMinMW][tech] * duration / scaling_factor)
            @constraint(model, model[:eDeploymentDeclineEnergy][t, p_idx] >= -settings[:InertiaMinMW][tech] * duration / scaling_factor)
        end
    end

    return nothing
end

"""
    add_to_deployment_inertia!(y, model, settings)

Add the new capacity of edge or storage `y` to the deployment inertia expressions of its
`Inertia_category`, net of its previous period's new capacity scaled by `1 + cagr`
(growth) or `1 - cadr` (decline). Edges (power, MW) and storage (energy, MWh) go into
separate expressions.
"""
function add_to_deployment_inertia!(y::Union{AbstractEdge,AbstractStorage}, model::Model, settings::NamedTuple)
    category = Inertia_category(y)
    (settings[:DeploymentInertia] && !isnothing(category) && category ∈ settings[:TechsWithInertia]) || return nothing

    growth, decline = y isa AbstractStorage ?
        (:eDeploymentGrowthEnergy, :eDeploymentDeclineEnergy) :
        (:eDeploymentGrowth, :eDeploymentDecline)

    p = period_index(y)
    prev = p > 1 ? new_capacity_track(y, p - 1) : 0.0
    add_to_expression!(model[growth][category, p], new_capacity(y) - (1 + cagr(y)) * prev)
    add_to_expression!(model[decline][category, p], new_capacity(y) - (1 - cadr(y)) * prev)

    return nothing
end
