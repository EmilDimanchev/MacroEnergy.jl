function add_learning!(system::System, model::Model, period_idx::Int, settings::NamedTuple)
    ```
    Builds endogenous technological learning formulation. The main purpose is to formulate the endogenous investment cost, called "annualized_investment_cost_with_learning", which is used in edge.jl for any learning technologies

    Inputs:
    Takes a system input because we need to combine new_capacity across edges of the same "learning_type" attribute to determine the amount of learning for a given technology. e.g., solar costs depend on total capacity expansion across all solar edges.
    ```

    learning_techs = settings[:LearningTechnologies]
    n_learning_techs = length(learning_techs)

    n_segments = 4
    learning_pwl_segment_chosen = @variable(model, [y in 1:n_learning_techs, k in 1:n_segments+1], binary=true, base_name = "vBINSEG_LEARNINGTYPE_$(period_idx)_$(y)_seg_$k")
    @constraint(model, [y in 1:n_learning_techs], sum(learning_pwl_segment_chosen[y,k] for k in 1:n_segments+1) == 1)


    # Need to loop through edges here since the function is called for a whole system
    edges = get_edges(system)

    for e in edges
        if occursin("_transmission_edge", string(e.id))
            nothing  # Skip transmission lines
        else
        
            if learning_type(e) in learning_techs

                if max_cumul_capacity(e) == Inf || max_cumul_capacity(e) == -1
                    error(string(e.id, " is a learning technology but max cumulative capacity is incorrectly specified"))
                end
        
                # Find position in learning techs list
                learning_type_index = findfirst(x -> x == learning_type(e), learning_techs)

                # Number of segments
                # n_segments = 4

                segment_length = (max_cumul_capacity(e)-cumulative_external_capacity(e))/n_segments
                
                # Define (x,y) coordinates for piece-wise linear curve (cumulative cost as a function of cumulative capacity added)
                x_points = zeros(n_segments+1)
                y_points = zeros(n_segments+1)
                
                # Compute coordinates
                for k in 1:n_segments+1    
                    x_points[k] = (k-1)*(segment_length)+cumulative_external_capacity(e)
                    # Estimate per-unit CAPEX cost for a given cumulative capacity 
                    cost_point = investment_cost(e)*(x_points[k]/cumulative_external_capacity(e))^(-learning_parameter(e))
                    # Estimate cost from fixed capacity points
                    y_points[k] = (1/(1-learning_parameter(e)))*(x_points[k]*cost_point-investment_cost(e)*cumulative_external_capacity(e))
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
                # e.segments_sos1 = @variable(model, [k in 1:n_segments+1], binary=true, base_name = "vSOS1SEG_$(id(e))_stage$(period_index(e))_seg_$k")
                # @constraint(model, [k in 1:n_segments+1], segments_sos1(e)[k] <= 1)
                # @constraint(model, sum(segments_sos1(e)[k] for k in 1:n_segments+1) == 1)
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
                
                # println(string(e.id," points"))
                # println(x_points)
                # println(y_points)
                # println("All slopes")
                # println(e.pwl_cost_slopes)

                # Determine chosen segment
                # Ensure strict inequality
                epsilon_learning = cumulative_external_capacity(e)/1e6
                ϵ = ones(length(x_points))*epsilon_learning
                @constraint(model, [k in 2:n_segments+1], cumulative_experience(e)[k] >= (x_points[k-1] + ϵ[k-1]) * learning_pwl_segment_chosen[learning_type_index, k])
                @constraint(model, [k in 1:n_segments+1], cumulative_experience(e)[k] <= x_points[k] * learning_pwl_segment_chosen[learning_type_index, k])

                # Slope reached after building new capacity
                e.learning_pwl_slope = @expression(model, sum(learning_pwl_segment_chosen[learning_type_index, k] * pwl_cost_slopes(e)[k] for k in 1:n_segments+1))
                e.learning_pwl_track[period_index(e)] = learning_pwl_slope(e)
                e.segments_sos1_track[period_index(e)] = learning_pwl_segment_chosen[learning_type_index, :]
                
                # Determine investment cost
                # Depends on learning lag
                if curr_period <= cc_duration(e)
                    e.annualized_investment_cost_with_learning = annualized_investment_cost(e)*new_capacity(e)
                    
                    if settings[:ProjectDevelopment]
                    # Shadow 
                        e.annualized_investment_cost_with_learning_de = de_annualized_cost(e)*new_de_capacity(e)
                        e.annualized_investment_cost_with_learning_af = af_annualized_cost(e)*new_af_capacity(e)
                        e.annualized_investment_cost_with_learning_cc = cc_annualized_cost(e)*new_cc_capacity(e)
                    end

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
                    big_M_capacity = 10000

                    @constraint(model, [k in 1:n_segments+1], e.new_capacity - e.aux_new_capacity[k] >= 0)
                    # Big M constraints
                    @constraint(model, [k in 1:n_segments+1], e.new_capacity - e.aux_new_capacity[k] <= big_M_capacity*(1-segments_sos1_prev(e)[k]))
                    @constraint(model, [k in 1:n_segments+1], e.aux_new_capacity[k] <= big_M_capacity*e.segments_sos1_prev[k])
                    e.annualized_investment_cost_with_learning = @expression(model, sum(e.pwl_cost_slopes[k]*e.aux_new_capacity[k]*annualization_factor(e) for k in 1:n_segments+1))

                    if settings[:ProjectDevelopment]
                        # Shadow capacity DE
                        e.aux_new_capacity_de = @variable(model, [k in 1:n_segments+1], lower_bound = 0.0, base_name = "vAUXNEWCAPDE_$(id(e))_stage$(period_index(e))_seg_$k")
                        @constraint(model, [k in 1:n_segments+1], e.new_de_capacity - e.aux_new_capacity_de[k] >= 0)
                        # Big M constraints
                        @constraint(model, [k in 1:n_segments+1], e.new_de_capacity - e.aux_new_capacity_de[k] <= big_M_capacity*(1-segments_sos1_prev(e)[k]))
                        @constraint(model, [k in 1:n_segments+1], e.aux_new_capacity_de[k] <= big_M_capacity*e.segments_sos1_prev[k])
                        e.annualized_investment_cost_with_learning_de = @expression(model, sum(e.pwl_cost_slopes[k]*e.aux_new_capacity_de[k]*de_annualization_factor(e)*de_cost_perc(e) for k in 1:n_segments+1))

                        # Shadow capacity AF
                        e.aux_new_capacity_af = @variable(model, [k in 1:n_segments+1], lower_bound = 0.0, base_name = "vAUXNEWCAPAF_$(id(e))_stage$(period_index(e))_seg_$k")
                        @constraint(model, [k in 1:n_segments+1], e.new_af_capacity - e.aux_new_capacity_af[k] >= 0)
                        # Big M constraints
                        @constraint(model, [k in 1:n_segments+1], e.new_af_capacity - e.aux_new_capacity_af[k] <= big_M_capacity*(1-segments_sos1_prev(e)[k]))
                        @constraint(model, [k in 1:n_segments+1], e.aux_new_capacity_af[k] <= big_M_capacity*e.segments_sos1_prev[k])
                        e.annualized_investment_cost_with_learning_af = @expression(model, sum(e.pwl_cost_slopes[k]*e.aux_new_capacity_af[k]*de_annualization_factor(e)*de_cost_perc(e) for k in 1:n_segments+1))

                        # Shadow capacity CC
                        e.aux_new_capacity_cc = @variable(model, [k in 1:n_segments+1], lower_bound = 0.0, base_name = "vAUXNEWCAPCC_$(id(e))_stage$(period_index(e))_seg_$k")
                        @constraint(model, [k in 1:n_segments+1], e.new_cc_capacity - e.aux_new_capacity_cc[k] >= 0)
                        # Big M constraints
                        @constraint(model, [k in 1:n_segments+1], e.new_cc_capacity - e.aux_new_capacity_cc[k] <= big_M_capacity*(1-segments_sos1_prev(e)[k]))
                        @constraint(model, [k in 1:n_segments+1], e.aux_new_capacity_cc[k] <= big_M_capacity*e.segments_sos1_prev[k])
                        e.annualized_investment_cost_with_learning_cc = @expression(model, sum(e.pwl_cost_slopes[k]*e.aux_new_capacity_cc[k]*de_annualization_factor(e)*de_cost_perc(e) for k in 1:n_segments+1))
                    end
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
