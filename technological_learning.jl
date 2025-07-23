function add_learning!(system::System, model::Model)
    ```
    Builds endogenous technological learning formulation. The main purpose is to formulate the endogenous investment cost, called "annualized_investment_cost_with_learning", which is used in edge.jl for any learning technologies

    Inputs:
    Takes a system input because we need to combine new_capacity across edges of the same "learning_type" attribute to determine the amount of learning for a given technology. e.g., solar costs depend on total capacity expansion across all solar edges.
    ```

    # Need to loop through edges here since the function is called for a whole system
    edges = get_edges(system)

    for e in edges
        
        if learning_parameter(e) != 0.0
        
            if max_capacity(e) == Inf
                error("Maximum capacity not specified for learning technology")
            end
    
            # Number of segments
            n_segments = n_learning_pwl_segments(e)
            if n_segments == 0
                error("Number of segments not specified for learning technology")
            end
            segment_length = (max_capacity(e)-cumulative_capacity_init(e))/n_segments
            
            # Define (x,y) coordinates for piece-wise linear curve (cumulative cost as a function of cumulative capacity added)
            x_points = zeros(n_segments+1)
            y_points = zeros(n_segments+1)
            
            # Compute coordinates
            for k in 1:n_segments+1    
                x_points[k] = (k-1)*(segment_length)+cumulative_capacity_init(e)
                # Estimate per-unit CAPEX cost for a given cumulative capacity 
                cost_point = investment_cost(e)*(x_points[k]/cumulative_capacity_init(e))^(-learning_parameter(e))
                # Estimate cost from fixed capacity points
                y_points[k] = (1/(1-learning_parameter(e)))*(x_points[k]*cost_point-investment_cost(e)*cumulative_capacity_init(e))
            end

            # Slope computation for piece-wise linear curve
            # First segment represents no new capacity and no learning
            push!(e.pwl_cost_slopes, investment_cost(e))
            # Remaining segments:
            for k in 2:n_segments+1
                push!(e.pwl_cost_slopes, (y_points[k] - y_points[k-1])/(x_points[k]-x_points[k-1]))
            end
            
            # SOS1 variables for piece-wise linearization
            # e.segments_sos1 = @variable(model, [k in 1:n_segments+1], lower_bound = 0.0, base_name = "vSOS1SEG_$(id(e))_stage$(period_index(e))_seg_$k")
            e.segments_sos1 = @variable(model, [k in 1:n_segments+1], binary=true, base_name = "vSOS1SEG_$(id(e))_stage$(period_index(e))_seg_$k")
            # @constraint(model, [k in 1:n_segments+1], segments_sos1(e)[k] <= 1)
            @constraint(model, sum(segments_sos1(e)[k] for k in 1:n_segments+1) == 1)
            # SOS1 constraint ensuring only one value is nonzero
            # @constraint(model, segments_sos1(e) in SOS1())
            # Cumulative experience for estimating movement along the learning curve 
            e.cumulative_experience = @variable(model, [k in 1:n_segments+1], lower_bound = 0.0, base_name = "vCUMULCAP_$(id(e))_stage$(period_index(e))")
            
            # Learning is delayed by length of construction
            curr_period = period_index(e)
            cost_period = curr_period - cc_duration(e)
    
            # Learning from all edges of that type. 
            tech_edges = get_edges_of_type(system, learning_type(e))
            # Cumulative_experience combines existing capacity and all new capacity from modeled region and externally
            @constraint(model, sum(cumulative_experience(e)[k] for k in 1:n_segments+1) == sum(new_capacity_track(e,i) for i=1:curr_period, e in tech_edges) + cumulative_external_capacity(e))
            
            # Determine chosen segment
            # Ensure strict inequality
            epsilon_learning = cumulative_capacity_init(e)/1e6
            ϵ = ones(length(x_points))*epsilon_learning
            @constraint(model, [k in 2:n_segments+1], cumulative_experience(e)[k] >= (x_points[k-1] + ϵ[k-1]) * segments_sos1(e)[k])
            @constraint(model, [k in 1:n_segments+1], cumulative_experience(e)[k] <= x_points[k] * segments_sos1(e)[k])

            # println(string(e.id," points"))
            # println(x_points)
            # println(y_points)
            # println("All slopes")
            # println(e.pwl_cost_slopes)
            
            # Slope reached after building new capacity
            e.learning_pwl_slope = @expression(model, sum(segments_sos1(e)[k] * pwl_cost_slopes(e)[k] for k in 1:n_segments+1))
            e.learning_pwl_track[period_index(e)] = learning_pwl_slope(e)
            e.segments_sos1_track[period_index(e)] = segments_sos1(e)
            
            # Determine investment cost
            # Depends on learning lag
            if curr_period <= cc_duration(e)
                e.annualized_investment_cost_with_learning = annualized_investment_cost(e)*new_capacity(e)
                e.segments_sos1_prev = segments_sos1_track(e, curr_period)
                # For reporting purposes
                e.endog_annualized_cost = annualized_investment_cost(e)
                # Nonlinear version for benchmarking
                # e.endog_investment_cost = annualized_investment_cost(e)
            else
                e.segments_sos1_prev = segments_sos1_track(e, cost_period)
                # Linearize 
                e.aux_new_capacity = @variable(model, [k in 1:n_segments+1], lower_bound = 0.0, base_name = "vAUXNEWCAP_$(id(e))_stage$(period_index(e))_seg_$k")
                # Upper bound on new capacity in a given period
                big_M_capacity = max_new_capacity(e)

                @constraint(model, [k in 1:n_segments+1], e.new_capacity - e.aux_new_capacity[k] >= 0)
                # Big M constraints
                @constraint(model, [k in 1:n_segments+1], e.new_capacity - e.aux_new_capacity[k] <= big_M_capacity*(1-segments_sos1_prev(e)[k]))
                @constraint(model, [k in 1:n_segments+1], e.aux_new_capacity[k] <= big_M_capacity*e.segments_sos1_prev[k])
                e.annualized_investment_cost_with_learning = @expression(model, sum(e.pwl_cost_slopes[k]*e.aux_new_capacity[k]*annualization_factor(e) for k in 1:n_segments+1))
                ### Enf of linearization
                # # For reporting purposes
                e.endog_annualized_cost = @expression(model, sum(e.pwl_cost_slopes[k]*e.segments_sos1_prev[k]*annualization_factor(e) for k in 1:n_segments+1))
                # Nonlinear version for benchmarking
                # e.endog_investment_cost = learning_pwl_track(e, cost_period)*annualization_factor(e)
            end
        else
            # For reporting purposes
            e.endog_annualized_cost = annualized_investment_cost(e)
            # Nonlinear version for benchmarking
            # e.endog_investment_cost = annualized_investment_cost(e)
        end
    end
    return nothing
end

function get_edges_of_type(system::System, type::String)
    ```
    Collects edges that belong to the same learning type
    ```
    tech_edges = Vector{AbstractEdge}()
    edges = get_edges(system)
    for e in edges 
        if learning_type(e) == type
            push!(tech_edges, e)
        end
    end
    return tech_edges
end
