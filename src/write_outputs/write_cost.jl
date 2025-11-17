"""
Cost outputs - everything related to cost data extraction and output.
"""

## Write cost outputs ##
# This is the main function to write the cost outputs to a file.
"""
    write_costs(
        file_path::AbstractString, 
        system::System, 
        model::Union{Model,NamedTuple}; 
        scaling::Float64=1.0, 
        drop_cols::Vector{AbstractString}=String[]
    )

Write the optimal cost results for all assets/edges in a system to a file. 
The extension of the file determines the format of the file.

# Arguments
- `file_path::AbstractString`: The path to the file where the results will be written
- `system::System`: The system containing the assets/edges to analyze as well as the settings for the output
- `model::Union{Model,NamedTuple}`: The optimal model after the optimization
- `scaling::Float64`: The scaling factor for the results
- `drop_cols::Vector{AbstractString}`: Columns to drop from the DataFrame

# Returns
- `nothing`: The function returns nothing, but writes the results to the file
"""
function write_costs(
    file_path::AbstractString, 
    system::System, 
    model::Union{Model,NamedTuple};
    scaling::Float64=1.0, 
    drop_cols::Vector{<:AbstractString}=String[]
)
    @info "Writing discounted costs to $file_path"

    # Get costs and determine layout (wide or long)
    costs = get_optimal_discounted_costs(model; scaling)
    layout = get_output_layout(system, :Costs)

    if layout == "wide"
        default_drop_cols = ["case_name", "year", "commodity", "commodity_subtype", "zone", "resource_id", "component_id", "type"]
        # Only use default_drop_cols if user didn't specify any
        drop_cols = isempty(drop_cols) ? default_drop_cols : drop_cols
        costs = reshape_wide(costs)
    end

    write_dataframe(file_path, costs, drop_cols)
    return nothing
end

function write_undiscounted_costs(
    file_path::AbstractString, 
    system::System, 
    model::Union{Model,NamedTuple};
    scaling::Float64=1.0, 
    drop_cols::Vector{<:AbstractString}=String[]
)
    @info "Writing undiscounted costs to $file_path"

    # Get costs and determine layout (wide or long)
    costs = get_optimal_undiscounted_costs(model; scaling)
    layout = get_output_layout(system, :Costs)

    if layout == "wide"
        default_drop_cols = ["case_name", "year", "commodity", "commodity_subtype", "zone", "resource_id", "component_id", "type"]
        # Only use default_drop_cols if user didn't specify any
        drop_cols = isempty(drop_cols) ? default_drop_cols : drop_cols
        costs = reshape_wide(costs)
    end

    write_dataframe(file_path, costs, drop_cols)
    return nothing
end

## Cost extraction functions ##
"""
    Helper function to extract discounted costs from the optimization results and return them as a DataFrame.
"""
function get_optimal_discounted_costs(model::Union{Model,NamedTuple}; scaling::Float64=1.0)
    @debug " -- Getting optimal discounted costs for the system."
    costs = prepare_discounted_costs(model, scaling)
    costs[!, (!isa).(eachcol(costs), Vector{Missing})] # remove missing columns
end

function get_optimal_undiscounted_costs(model::Union{Model,NamedTuple}; scaling::Float64=1.0)
    @debug " -- Getting optimal discounted costs for the system."
    costs = prepare_undiscounted_costs(model, scaling)
    costs[!, (!isa).(eachcol(costs), Vector{Missing})] # remove missing columns
end

# The following functions will return:
# - Variable cost
# - Fixed cost
# - Total cost
function prepare_undiscounted_costs(model::Union{Model,NamedTuple}, scaling::Float64=1.0)
    fixed_cost = value(model[:eFixedCost])
    variable_cost = value(model[:eVariableCost])
    total_cost = fixed_cost + variable_cost
    return DataFrame(
        case_name = fill(:missing, 3),
        commodity = fill(:all, 3),
        commodity_subtype = fill(:cost, 3),
        zone = fill(:all, 3),
        resource_id = fill(:all, 3),
        component_id = fill(:all, 3),
        type = fill(:Cost, 3),
        variable = [:FixedCost, :VariableCost, :TotalCost],
        year = fill(:missing, 3),
        value = [fixed_cost, variable_cost, total_cost] .* scaling^2
    )
end

function prepare_discounted_costs(model::Union{Model,NamedTuple}, scaling::Float64=1.0)
    fixed_cost = value(model[:eDiscountedFixedCost])
    variable_cost = value(model[:eDiscountedVariableCost])
    total_cost = fixed_cost + variable_cost
    return DataFrame(
        case_name = fill(:missing, 3),
        commodity = fill(:all, 3),
        commodity_subtype = fill(:cost, 3),
        zone = fill(:all, 3),
        resource_id = fill(:all, 3),
        component_id = fill(:all, 3),
        type = fill(:Cost, 3),
        variable = [:DiscountedFixedCost, :DiscountedVariableCost, :DiscountedTotalCost],
        year = fill(:missing, 3),
        value = [fixed_cost, variable_cost, total_cost] .* scaling^2
    )
end

function compute_fixed_costs!(system::System, model::Model)
    for a in system.assets
        compute_fixed_costs!(a, model)
    end
end

function compute_fixed_costs!(a::AbstractAsset, model::Model)
    for t in fieldnames(typeof(a))
        compute_fixed_costs!(getfield(a, t), model)
    end
end

function compute_fixed_costs!(g::Union{Node,Transformation},model::Model)
    return nothing
end

function compute_investment_costs!(system::System, model::Model)
    for a in system.assets
        compute_investment_costs!(a, model)
    end
end

function compute_investment_costs!(a::AbstractAsset, model::Model)
    for t in fieldnames(typeof(a))
        compute_investment_costs!(getfield(a, t), model)
    end
end

function compute_investment_costs!(g::Union{Node,Transformation},model::Model)
    return nothing
end

function create_discounted_cost_expressions!(model::Model, system::System, settings::NamedTuple)
    
    period_index = system.time_data[:Electricity].period_index;
    discount_rate = settings.DiscountRate
    period_lengths = collect(settings.PeriodLengths)
    cum_years = sum(period_lengths[i] for i in 1:period_index-1; init=0)
    discount_factor = 1/( (1 + discount_rate)^cum_years)
    
    unregister(model,:eDiscountedFixedCost)

    if isa(solution_algorithm(settings[:SolutionAlgorithm]), Myopic)

        unregister(model,:eDiscountedInvestmentFixedCost)
        add_costs_not_seen_by_myopic!(system, settings)
        unregister(model,:eInvestmentFixedCost)
        model[:eInvestmentFixedCost] = AffExpr(0.0)
        compute_investment_costs!(system, model)
        
        model[:eDiscountedInvestmentFixedCost] = discount_factor * model[:eInvestmentFixedCost]
        
        model[:eDiscountedFixedCost] = model[:eDiscountedInvestmentFixedCost] + model[:eOMFixedCostByPeriod][period_index]

    elseif isa(solution_algorithm(settings[:SolutionAlgorithm]), Monolithic) || isa(solution_algorithm(settings[:SolutionAlgorithm]), Benders)
        # Perfect foresight  cases (applies to both Monolithic and Benders)
        model[:eDiscountedFixedCost] = model[:eFixedCostByPeriod][period_index]
    else
        nothing
    end

    unregister(model,:eDiscountedVariableCost)
    model[:eDiscountedVariableCost] = model[:eVariableCostByPeriod][period_index]
end

function compute_undiscounted_costs!(model::Model, system::System, settings::NamedTuple)
    
    period_lengths = collect(settings.PeriodLengths)
    discount_rate = settings.DiscountRate
    period_index = system.time_data[:Electricity].period_index;

    undo_discount_fixed_costs!(system, settings)
    unregister(model,:eFixedCost)
    model[:eFixedCost] = AffExpr(0.0)
    model[:eOMFixedCost] = AffExpr(0.0)
    model[:eInvestmentFixedCost] = AffExpr(0.0)
    compute_fixed_costs!(system, model)
    model[:eFixedCost] = model[:eInvestmentFixedCost] + model[:eOMFixedCost] 

    cum_years = sum(period_lengths[i] for i in 1:period_index-1; init=0);
    discount_factor = 1/( (1 + discount_rate)^cum_years)
    opexmult = sum([1 / (1 + discount_rate)^(i) for i in 1:period_lengths[period_index]])

    model[:eVariableCost] = period_lengths[period_index]*model[:eVariableCostByPeriod][period_index]/(discount_factor * opexmult)

end