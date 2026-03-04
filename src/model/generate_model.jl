

function generate_model(case::Case)

    periods = get_periods(case)
    settings = get_settings(case)
    num_periods = number_of_periods(case)

    @info("Generating model")

    @info("Deployment inertia set to $(settings[:DeploymentInertia])")
    @info("Project development set to $(settings[:ProjectDevelopment])")
    @info("Technology learning set to $(settings[:TechnologyLearning])")

    start_time = time();

    model = Model()

    @variable(model, vREF == 1)

    fixed_cost = Dict()
    om_fixed_cost = Dict()
    investment_cost = Dict()
    variable_cost = Dict()

    # Initialize capacity reserve margin structure before period loop
    # Collect all CRM zones from all periods
    all_crm_zones = Set{Symbol}()
    @info("Scanning for capacity reserve margin zones across all periods...")
    for (idx, system) in enumerate(periods)
        crm_nodes = get_capacity_reserve_margin_nodes(system)
        @info(" -- Initial scan period $idx: Found CRM zones: $(collect(keys(crm_nodes)))")
        @info(" -- Initial scan period $idx: Number of locations: $(length(system.locations))")
        union!(all_crm_zones, keys(crm_nodes))
    end
    
    # Create the 2D indexed expression if there are any CRM zones
    if !isempty(all_crm_zones)
        @info(" -- Initializing capacity reserve margin structure for zones: $(collect(all_crm_zones))")
        # Initialize with zeros - will be populated during each period
        @expression(model, eCapacityReserveMargin[k in all_crm_zones, p in 1:num_periods], AffExpr(0.0))
    else
        @info(" -- No capacity reserve margin zones found in any period")
    end
            

    for (period_idx,system) in enumerate(periods)

        @info(" -- Period $period_idx")

        model[:eFixedCost] = AffExpr(0.0)
        model[:eInvestmentFixedCost] = AffExpr(0.0)
        model[:eOMFixedCost] = AffExpr(0.0)
        model[:eVariableCost] = AffExpr(0.0)

        @info(" -- Adding linking variables")
        add_linking_variables!(system, model) 

        @info(" -- Defining available capacity")
        define_available_capacity!(system, model)
        
        @info(" -- Generating planning model")
        if settings[:TechnologyLearning] == true
            @info(" -- Adding technology learning")
            add_learning!(system, model, period_idx, settings)
    end
        planning_model!(system, model, settings)

        if system.settings.Retrofitting
            @info(" -- Adding retrofit constraints")
            add_retrofit_constraints!(system, period_idx, model)
        end
        
        @info(" -- Including age-based retirements")
        add_age_based_retirements!.(system.assets, model, Ref(settings))

        if period_idx < num_periods
            @info(" -- Available capacity in period $(period_idx) is being carried over to period $(period_idx+1)")
            carry_over_capacities!(periods[period_idx+1], system, settings)
        end

        @info(" -- Generating operational model")
        operation_model!(system, model, settings)

        model[:eFixedCost] = model[:eInvestmentFixedCost] + model[:eOMFixedCost]
        fixed_cost[period_idx] = model[:eFixedCost];
        investment_cost[period_idx] = model[:eInvestmentFixedCost];
        om_fixed_cost[period_idx] = model[:eOMFixedCost];
	    unregister(model,:eFixedCost)
        unregister(model,:eInvestmentFixedCost)
        unregister(model,:eOMFixedCost)

        variable_cost[period_idx] = model[:eVariableCost];
        unregister(model,:eVariableCost)

    end

    #The settings are the same in all case, we have a single settings file that gets copied into each system struct
    period_lengths = collect(settings.PeriodLengths)

    discount_rate = settings.DiscountRate

    cum_years = [sum(period_lengths[i] for i in 1:s-1; init=0) for s in 1:num_periods];

    discount_factor = 1 ./ ( (1 + discount_rate) .^ cum_years)

    @expression(model, eFixedCostByPeriod[s in 1:num_periods], discount_factor[s] * fixed_cost[s])

    @expression(model, eInvestmentFixedCostByPeriod[s in 1:num_periods], discount_factor[s] * investment_cost[s])

    @expression(model, eOMFixedCostByPeriod[s in 1:num_periods], discount_factor[s] * om_fixed_cost[s])

    @expression(model, eFixedCost, sum(eFixedCostByPeriod[s] for s in 1:num_periods))

    opexmult = [sum([1 / (1 + discount_rate)^(i) for i in 1:period_lengths[s]]) for s in 1:num_periods]

    @expression(model, eVariableCostByPeriod[s in 1:num_periods], discount_factor[s] * opexmult[s] * variable_cost[s])

    @expression(model, eVariableCost, sum(eVariableCostByPeriod[s] for s in 1:num_periods))

    @objective(model, Min, model[:eFixedCost] + model[:eVariableCost])

    @info(" -- Model generation complete, it took $(time() - start_time) seconds")

    return model
    
end

function planning_model!(system::System, model::Model, settings::NamedTuple)

    # if settings[:TechnologyLearning] == true
    #     @info(" -- Adding technology learning")
    #     add_learning!(system, model, ["wind", "solar"])
    # end

    # Check if any nodes have capacity reserve margin data
    capacity_reserve_margin_nodes = get_capacity_reserve_margin_nodes(system)
    if !isempty(capacity_reserve_margin_nodes) && haskey(model, :eCapacityReserveMargin)
        @info(" -- Including capacity reserve margins: $(keys(capacity_reserve_margin_nodes))")
        # Get period_idx from first node (all nodes in a system have the same period_index)
        first_zone_nodes = first(values(capacity_reserve_margin_nodes))
        period_idx = period_index(first_zone_nodes[1])
        prepare_capacity_reserve_margin!(system, model, period_idx)
    elseif !isempty(capacity_reserve_margin_nodes) && !haskey(model, :eCapacityReserveMargin)
        @warn("Found capacity reserve margin nodes but eCapacityReserveMargin expression was not initialized. This suggests the initial scan did not find these zones.")
    end

    planning_model!.(system.locations, Ref(model), Ref(settings))

    planning_model!.(system.assets, Ref(model), Ref(settings))

    add_constraints_by_type!(system, model, PlanningConstraint, settings)

end


function operation_model!(system::System, model::Model, settings::NamedTuple)

    operation_model!.(system.locations, Ref(model), Ref(settings))

    operation_model!.(system.assets, Ref(model), Ref(settings))

    add_constraints_by_type!(system, model, OperationConstraint, settings)

end

function planning_model!(a::AbstractAsset, model::Model, settings::NamedTuple)
    for t in fieldnames(typeof(a))
        planning_model!(getfield(a, t), model, settings)
    end
    return nothing
end

function operation_model!(a::AbstractAsset, model::Model, settings::NamedTuple)
    for t in fieldnames(typeof(a))
        operation_model!(getfield(a, t), model, settings)
    end
    return nothing
end

function add_linking_variables!(system::System, model::Model)

    add_linking_variables!.(system.locations, model)

    add_linking_variables!.(system.assets, model)

end

function add_linking_variables!(a::AbstractAsset, model::Model)
    for t in fieldnames(typeof(a))
        add_linking_variables!(getfield(a, t), model)
    end
end

function define_available_capacity!(system::System, model::Model)

    define_available_capacity!.(system.locations, model)

    define_available_capacity!.(system.assets, model)

end

function define_available_capacity!(a::AbstractAsset, model::Model)
    for t in fieldnames(typeof(a))
        define_available_capacity!(getfield(a, t), model)
    end
end

function add_age_based_retirements!(a::AbstractAsset,model::Model, settings::NamedTuple)

    for t in fieldnames(typeof(a))
        y = getfield(a, t)
        if isa(y,AbstractEdge) || isa(y,AbstractStorage)
            if retirement_period(y) > 0 || min_retired_capacity_track(y) > 0.0 ### Otherwise the constraint is trivially satisfied because the left hand side is zero
                push!(y.constraints, AgeBasedRetirementConstraint())
                add_model_constraint!(y.constraints[end], y, model, settings)
            end
        end
    end

end

#### All new capacity built up to the retirement period must retire in the current period
### Key assumption: all capacity decisions are taken at the very beggining of the period.
### Example: Consider four periods of lengths [5,5,5,5] and technology with a lifetime of 15 years. 
### All capacity built in period 1 will have at most 10 years old at the start of period 3, so no age based retirement will be needed.
### In period 4 we will have to retire at least all new capacity built up until period get_retirement_period(4,15,[5,5,5,5])=1
function get_retirement_period(cur_period::Int,lifetime::Int,period_lengths::Vector{Int})

    return maximum(filter(r -> sum(period_lengths[t] for t in r:cur_period-1; init=0) >= lifetime,1:cur_period-1);init=0)

end

function compute_retirement_period!(system::System, period_lengths::Vector{Int})
    
    for a in system.assets
        compute_retirement_period!(a, period_lengths)
    end

    return nothing
end

function compute_retirement_period!(a::AbstractAsset, period_lengths::Vector{Int})

    for t in fieldnames(typeof(a))
        y = getfield(a, t)
        
        if :retirement_period ∈ Base.fieldnames(typeof(y))
            if can_retire(y)
                y.retirement_period = get_retirement_period(period_index(y),lifetime(y),period_lengths)
            end
        end
    end

    return nothing
end

function carry_over_capacities!(system::System, system_prev::System, settings::NamedTuple; perfect_foresight::Bool = true)

    for a in system.assets
        a_prev_index = findfirst(id.(system_prev.assets).==id(a))
        if isnothing(a_prev_index)
            @info("Skipping asset $(id(a)) as it was not present in the previous period")
            validate_existing_capacity(a)
        else
            a_prev = system_prev.assets[a_prev_index];
            carry_over_capacities!(a, a_prev, settings; perfect_foresight)
        end
    end

end

function carry_over_capacities!(a::AbstractAsset, a_prev::AbstractAsset, settings::NamedTuple; perfect_foresight::Bool = true)

    for t in fieldnames(typeof(a))
        carry_over_capacities!(getfield(a,t), getfield(a_prev,t), settings; perfect_foresight)
    end

end

function carry_over_capacities!(y::Union{AbstractEdge,AbstractStorage},y_prev::Union{AbstractEdge,AbstractStorage}, settings::NamedTuple; perfect_foresight::Bool = true)
    if has_capacity(y_prev)
        
        if perfect_foresight
            y.existing_capacity = capacity(y_prev)
        else
            y.existing_capacity = value(capacity(y_prev))
        end
        
        for prev_period in keys(new_capacity_track(y_prev))
            if perfect_foresight
                y.new_capacity_track[prev_period] = new_capacity_track(y_prev,prev_period)
                y.retired_capacity_track[prev_period] = retired_capacity_track(y_prev,prev_period)

                if isa(y, AbstractEdge)
                    y.retrofitted_capacity_track[prev_period] = retrofitted_capacity_track(y_prev,prev_period)
                else
                    continue # Storage does not have retrofitted capacity
                end
            else
                y.new_capacity_track[prev_period] = value(new_capacity_track(y_prev,prev_period))
                y.retired_capacity_track[prev_period] = value(retired_capacity_track(y_prev,prev_period))

                if isa(y, AbstractEdge)
                    y.retrofitted_capacity_track[prev_period] = value(retrofitted_capacity_track(y_prev,prev_period))
                else
                    continue # Storage does not have retrofitted capacity
                    
                end
            end
        end
        
    end

    for prev_period in keys(new_capacity_track(y_prev))
        if perfect_foresight
            
            # Learning
            if settings[:TechnologyLearning] && learning_type(y) in settings[:LearningTechnologies]
                
                y.endogenous_capex_track[prev_period] = endogenous_capex_track(y_prev, prev_period)
                
                y.endogenous_capex_segment_chosen_track[prev_period] = endogenous_capex_segment_chosen_track(y_prev,prev_period)
            end
            # Shadow capacity for project development 
            y.new_de_capacity_track[prev_period] = new_de_capacity_track(y_prev,prev_period)
            y.new_af_capacity_track[prev_period] = new_af_capacity_track(y_prev,prev_period)
            y.new_cc_capacity_track[prev_period] = new_cc_capacity_track(y_prev,prev_period)
            y.de_capacity_track[prev_period] = de_capacity_track(y_prev,prev_period)
            y.af_capacity_track[prev_period] = af_capacity_track(y_prev,prev_period)
            y.cc_capacity_track[prev_period] = cc_capacity_track(y_prev,prev_period)
        else
            # Speed limits not implemented for myopic yet
            
        end
    end


end
function carry_over_capacities!(g::Transformation,g_prev::Transformation, settings::NamedTuple; perfect_foresight::Bool = true)
    return nothing
end
function carry_over_capacities!(n::Node,n_prev::Node, settings::NamedTuple; perfect_foresight::Bool = true) 
    return nothing
end

function compute_annualized_costs!(system::System,settings::NamedTuple)
    for a in system.assets
        compute_annualized_costs!(a,settings)
    end
end

function compute_annualized_costs!(a::AbstractAsset,settings::NamedTuple)
    for t in fieldnames(typeof(a))
        compute_annualized_costs!(getfield(a, t),settings)
    end
end

function compute_annualized_costs!(y::Union{AbstractEdge,AbstractStorage},settings::NamedTuple)

    y.annualization_factor = wacc(y)>0 ? wacc(y) / (1 - (1 + wacc(y))^-capital_recovery_period(y))  : 1.0

    if isnothing(annualized_investment_cost(y)) || annualized_investment_cost(y) == 0.0
        if ismissing(wacc(y))
            y.wacc = settings.DiscountRate;
        end

        y.annualized_investment_cost = investment_cost(y)*annualization_factor(y)
    
    else
        # Check if CAPEX (i.e. investment_cost) was provided. If not, estimate it
        if isnothing(investment_cost(y)) || investment_cost(y) == 0.0
            y.investment_cost = annualized_investment_cost(y)/annualization_factor(y) 
        end

    end

    if settings[:ProjectDevelopment]
        # Distribute deployment cost in case deployment stage costs are included
        deployment_cost_perc = 1 - de_cost_perc(y) - af_cost_perc(y) - cc_cost_perc(y)

        # Update cost of deployment
        y.annualized_investment_cost = annualized_investment_cost(y)*deployment_cost_perc

        # Development annualized costs
        y.de_annualization_factor = de_wacc(y)>0 && de_cap_recovery(y) > 0 ? de_wacc(y) / (1 - (1 + de_wacc(y))^-de_cap_recovery(y))  : 1.0
        y.af_annualization_factor = af_wacc(y)>0 && af_cap_recovery(y) > 0 ? af_wacc(y) / (1 - (1 + af_wacc(y))^-af_cap_recovery(y))  : 1.0
        y.cc_annualization_factor = cc_wacc(y)>0 && cc_cap_recovery(y) > 0 ? cc_wacc(y) / (1 - (1 + cc_wacc(y))^-cc_cap_recovery(y))  : 1.0

        # Overwrite CC wacc if general wacc is provided
        y.cc_wacc = wacc(y) > 0 ? wacc(y) : cc_wacc(y)
        
        y.de_annualized_cost = investment_cost(y)*de_annualization_factor(y)*de_cost_perc(y)
        y.af_annualized_cost = investment_cost(y)*af_annualization_factor(y)*af_cost_perc(y)
        y.cc_annualized_cost = investment_cost(y)*cc_annualization_factor(y)*cc_cost_perc(y)

    else
        y.de_annualized_cost = 0.0
        y.af_annualized_cost = 0.0
        y.cc_annualized_cost = 0.0
    end
end

function compute_annualized_costs!(g::Transformation,settings::NamedTuple)
    return nothing
end
function compute_annualized_costs!(n::Node,settings::NamedTuple)
    return nothing
end

function discount_fixed_costs!(system::System, settings::NamedTuple)
    for a in system.assets
        discount_fixed_costs!(a, settings)
    end
end

function discount_fixed_costs!(a::AbstractAsset,settings::NamedTuple)
    for t in fieldnames(typeof(a))
        discount_fixed_costs!(getfield(a, t), settings)
    end
end

function discount_fixed_costs!(y::Union{AbstractEdge,AbstractStorage},settings::NamedTuple)
    
    # Number of years of payments that are remaining
    model_years_remaining = sum(settings.PeriodLengths[period_index(y):end]; init = 0);

    # Myopic only considers costs within modeled period. Costs that are consequently omitted will be added after the model run when reporting results
    if isa(solution_algorithm(settings[:SolutionAlgorithm]), Myopic)
        payment_years_remaining = min(capital_recovery_period(y), settings.PeriodLengths[period_index(y)]);
    elseif isa(solution_algorithm(settings[:SolutionAlgorithm]), Monolithic) || isa(solution_algorithm(settings[:SolutionAlgorithm]), Benders)
        payment_years_remaining = min(capital_recovery_period(y), model_years_remaining);
        if settings[:ProjectDevelopment] 
            de_payment_years_remaining = min(de_cap_recovery(y), model_years_remaining);
            af_payment_years_remaining = min(af_cap_recovery(y), model_years_remaining);
            cc_payment_years_remaining = min(cc_cap_recovery(y), model_years_remaining);
        end
    else
        # Placeholder for other future cases like rolling horizon
        nothing
    end

    # y.annualized_investment_cost = annualized_investment_cost(y) * sum(1 / (1 + settings.DiscountRate)^s for s in 1:payment_years_remaining; init=0);

    y.annuities_mult = sum(1 / (1 + settings.DiscountRate)^s for s in 1:payment_years_remaining; init=0);
    if settings[:ProjectDevelopment] 
        y.de_annuities_mult = sum(1 / (1 + settings.DiscountRate)^s for s in 1:de_payment_years_remaining; init=0);
        y.af_annuities_mult = sum(1 / (1 + settings.DiscountRate)^s for s in 1:af_payment_years_remaining; init=0);
        y.cc_annuities_mult = sum(1 / (1 + settings.DiscountRate)^s for s in 1:cc_payment_years_remaining; init=0);
    end
    
    opexmult = sum([1 / (1 + settings.DiscountRate)^(i) for i in 1:settings.PeriodLengths[period_index(y)]])

    y.fixed_om_cost = fixed_om_cost(y) * opexmult

end

function discount_fixed_costs!(g::Transformation,settings::NamedTuple)
    return nothing
end
function discount_fixed_costs!(n::Node,settings::NamedTuple)
    return nothing
end

function undo_discount_fixed_costs!(system::System, settings::NamedTuple)
    for a in system.assets
        undo_discount_fixed_costs!(a, settings)
    end
end

function undo_discount_fixed_costs!(a::AbstractAsset,settings::NamedTuple)
    for t in fieldnames(typeof(a))
        undo_discount_fixed_costs!(getfield(a, t), settings)
    end
end

function undo_discount_fixed_costs!(y::Union{AbstractEdge,AbstractStorage},settings::NamedTuple)
    # Number of years of payments that are remaining
    model_years_remaining = sum(settings.PeriodLengths[period_index(y):end]; init = 0);
    
    # Include all annuities within the modeling horizon for all cases (including Myopic), since undiscounting only concerns reporting of results 
    payment_years_remaining = min(capital_recovery_period(y), model_years_remaining);

    y.annualized_investment_cost = payment_years_remaining * annualized_investment_cost(y) / sum(1 / (1 + settings.DiscountRate)^s for s in 1:payment_years_remaining; init=0);

    opexmult = sum([1 / (1 + settings.DiscountRate)^(i) for i in 1:settings.PeriodLengths[period_index(y)]])
    y.fixed_om_cost = settings.PeriodLengths[period_index(y)]*fixed_om_cost(y) / opexmult
end
function undo_discount_fixed_costs!(g::Transformation,settings::NamedTuple)
    return nothing
end
function undo_discount_fixed_costs!(n::Node,settings::NamedTuple)
    return nothing
end

function add_costs_not_seen_by_myopic!(system::System, settings::NamedTuple)
    for a in system.assets
        add_costs_not_seen_by_myopic!(a, settings)
    end
end

function add_costs_not_seen_by_myopic!(y::Union{AbstractEdge,AbstractStorage}, settings::NamedTuple)
    
    model_years_remaining = sum(settings.PeriodLengths[period_index(y):end]; init = 0);
    payment_years_remaining = min(capital_recovery_period(y), model_years_remaining);

    # Need to get the coefficient used by the model
    payment_years_remaining_myopic = min(capital_recovery_period(y), settings.PeriodLengths[period_index(y)]);

    total_mult = sum(1 / (1 + settings.DiscountRate)^s for s in 1:payment_years_remaining; init=0)
    myopic_mult = sum(1 / (1 + settings.DiscountRate)^s for s in 1:payment_years_remaining_myopic; init=0)

    y.annualized_investment_cost = annualized_investment_cost(y) * total_mult/myopic_mult;

    # TODO add myopic cost for project development stages
end

function add_costs_not_seen_by_myopic!(a::AbstractAsset,settings::NamedTuple)
    for t in fieldnames(typeof(a))
        add_costs_not_seen_by_myopic!(getfield(a, t), settings)
    end
end

function add_costs_not_seen_by_myopic!(g::Transformation,settings::NamedTuple)
    return nothing
end

function add_costs_not_seen_by_myopic!(n::Node,settings::NamedTuple)
    return nothing
end

function validate_existing_capacity(asset::AbstractAsset)
    for t in fieldnames(typeof(asset))
        if isa(getfield(asset, t), AbstractEdge) || isa(getfield(asset, t), AbstractStorage)
            if existing_capacity(getfield(asset, t)) > 0
                msg = " -- Asset with id: \"$(id(asset))\" has existing capacity equal to $(existing_capacity(getfield(asset,t)))"
                msg *= "\nbut it was not present in the previous period. Please double check that the input data is correct."
                @warn(msg)
            end
        end
    end
end

function prepare_capacity_reserve_margin!(system::System, model::Model, period_idx::Int)

    capacity_reserve_margin_nodes = get_capacity_reserve_margin_nodes(system)
    capacity_reserve_margin_ids = keys(capacity_reserve_margin_nodes)
    
    # Build margin dictionary from node data instead of settings
    capacity_reserve_margins = Dict{Symbol,Float64}()
    for (crm_id, nodes) in capacity_reserve_margin_nodes
        # Get margin from first node in the zone (all should have same value)
        margin = capacity_reserve_margin(nodes[1])
        if ismissing(margin)
            @error("Node $(id(nodes[1])) has capacity_reserve_margin_id=$crm_id but no capacity_reserve_margin value")
            error("Missing capacity_reserve_margin value for node $(id(nodes[1]))")
        end
        capacity_reserve_margins[crm_id] = margin
        
        # Validate all nodes in zone have same margin
        for n in nodes[2:end]
            node_margin = capacity_reserve_margin(n)
            if !ismissing(node_margin) && node_margin != margin
                @warn("Inconsistent capacity_reserve_margin values in zone $crm_id: node $(id(n)) has $node_margin vs $(margin) from node $(id(nodes[1]))")
            end
        end
    end
    
    # Check for deprecated settings usage
    if !isempty(system.settings.CapacityReserveMargin)
        @warn("CapacityReserveMargin in settings is deprecated. Values from node files will be used instead.")
    end

    # Calculate peak demand and corresponding timestep for each zone
    peak_demand = Dict{Symbol,Float64}()
    peak_demand_timestep = Dict{Symbol,Int}()
    for k in capacity_reserve_margin_ids
        # Sum demand across all nodes in the zone for each timestep
        total_demand_timeseries = [sum(demand(n, t) for n in capacity_reserve_margin_nodes[k]) for t in 1:length(demand(capacity_reserve_margin_nodes[k][1]))]
        peak_demand[k] = maximum(total_demand_timeseries)
        peak_demand_timestep[k] = argmax(total_demand_timeseries)
    end
    
    # Store peak demand timestep in model for use by edges (indexed by period)
    if !haskey(model.ext, :peak_demand_timestep)
        model.ext[:peak_demand_timestep] = Dict{Int,Dict{Symbol,Int}}()
    end
    model.ext[:peak_demand_timestep][period_idx] = peak_demand_timestep
    
    required_capacity = Dict{Symbol,Float64}(k=> (1 + capacity_reserve_margins[k]) * peak_demand[k] for k in capacity_reserve_margin_ids)

    if any(capacity_reserve_margins[k] == 0.0 for k in capacity_reserve_margin_ids)
        msg  = " ++ Capacity reserve margin for some zones is set to 0.0"
        @warn(msg)
    end

    # Set the RHS of the existing expression for this period
    if !haskey(model, :eCapacityReserveMargin)
        error("eCapacityReserveMargin expression not found in model. This should have been initialized before the period loop.")
    end
    
    for k in capacity_reserve_margin_ids
        model[:eCapacityReserveMargin][k, period_idx] = -required_capacity[k]*AffExpr(1)
    end

    push!(system.constraints, CapacityReserveMarginConstraint())

    return nothing
    
end

function get_capacity_reserve_margin_nodes(system::System)
    capacity_reserve_margin_nodes = Dict{Symbol,Vector{Node}}()
    nodes = get_nodes(system)
    node_count = 0
    location_count = 0
    for n in nodes
        # Skip if this is a Location rather than a Node
        if !isa(n, Node)
            location_count += 1
            continue
        end
        node_count += 1
        crm_id = capacity_reserve_margin_id(n)
        if !ismissing(crm_id)
            if !haskey(capacity_reserve_margin_nodes,crm_id)
                capacity_reserve_margin_nodes[crm_id] = [n]
            else
                push!(capacity_reserve_margin_nodes[crm_id], n)
            end
        end
    end
    @info("get_capacity_reserve_margin_nodes: Processed $node_count nodes and $location_count locations, found $(length(capacity_reserve_margin_nodes)) CRM zones")
    return capacity_reserve_margin_nodes
end