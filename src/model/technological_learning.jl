"""
Adds learning to model for one period, for each technology in `settings[:LearningTechnologies]`:

- cumulative experience = `init_cumul_capacity` + all new capacity built so far
  across every edge of that technology.
- binary variables select the segment of the piece-wise linear learning curve
  that the cumulative experience falls in.

The piece-wise learning curves (`pwl_x_points`, `pwl_capex_slopes`) are inputs
computed beforehand by `prepare_learning_curves!`.
"""
function add_learning!(system::System, model::Model, period_idx::Int, settings::NamedTuple)

    learning_techs = settings[:LearningTechnologies]

    for (tech_idx, learning_tech) in enumerate(learning_techs)

        learning_tech_edges = get_edges_of_type(system, learning_tech)
        isempty(learning_tech_edges) && continue

        n_segments = learning_n_segments(learning_tech_edges, learning_tech)

        # Segment of piece-wise linear curve chosen for this learning technology
        endogenous_capex_segment_chosen = @variable(model, [k in 1:n_segments+1], binary=true, base_name = "vBINSEG_LEARNINGTYPE_$(period_idx)_$(tech_idx)_seg")
        @constraint(model, sum(endogenous_capex_segment_chosen[k] for k in 1:n_segments+1) == 1)

        # All edges of the same learning technology have the same breakpoints and initial capacity
        ref_edge = first(learning_tech_edges)
        x_points = pwl_x_points(ref_edge)
        curr_period = period_index(ref_edge)

        cumulative_experience_tech = @variable(model, [k in 1:n_segments+1], lower_bound = 0.0, base_name = "vCUMULCAP_$(learning_tech)_stage$(curr_period)")

        # Cumulative experience combines initial capacity and all new capacity built
        # so far across every edge of the technology
        @constraint(model, sum(cumulative_experience_tech[k] for k in 1:n_segments+1) == sum(new_capacity_track(f, i) for i=1:curr_period, f in learning_tech_edges) + init_cumul_capacity(ref_edge))

        # Determine chosen segment
        # Make segment-selection inequality strict (will scale with parameter scaling based on the x points)
        ϵ = 1e-3 * (x_points[2] - x_points[1])
        # Set segment
        @constraint(model, [k in 2:n_segments+1], cumulative_experience_tech[k] >= (x_points[k-1] + ϵ) * endogenous_capex_segment_chosen[k])
        @constraint(model, [k in 1:n_segments+1], cumulative_experience_tech[k] <= x_points[k] * endogenous_capex_segment_chosen[k])

        for e in learning_tech_edges

            # Shared technology-level variables, kept on the edge for access/reporting
            e.cumulative_experience = cumulative_experience_tech

            # Learning is delayed by learning_delay periods (set in prepare_learning_curves!)
            cost_period = curr_period - learning_delay(e)

            # Slope reached after building new capacity (edge-specific: its own slopes)
            e.endogenous_capex = @expression(model, sum(endogenous_capex_segment_chosen[k] * pwl_capex_slopes(e)[k] for k in 1:n_segments+1))
            e.endogenous_capex_track[period_index(e)] = endogenous_capex(e)
            e.endogenous_capex_segment_chosen_track[period_index(e)] = endogenous_capex_segment_chosen

            # Determine investment cost
            # Depends on learning lag
            if curr_period <= cc_duration(e)

                e.endog_annualized_investment_cost_times_newcapacity = annualized_investment_cost(e)*new_capacity(e)

                if settings[:ProjectDevelopment]
                    e.endog_annualized_investment_cost_times_newcapacity_de = de_annualized_cost(e)*new_de_capacity(e)
                    e.endog_annualized_investment_cost_times_newcapacity_af = af_annualized_cost(e)*new_af_capacity(e)
                    e.endog_annualized_investment_cost_times_newcapacity_cc = cc_annualized_cost(e)*new_cc_capacity(e)
                end

                # For reporting purposes
                e.endogenous_capex_segment_chosen_from_relevant_period = endogenous_capex_segment_chosen_track(e, curr_period)
                e.endog_capex_cost = investment_cost(e)

            else
                e.endogenous_capex_segment_chosen_from_relevant_period = endogenous_capex_segment_chosen_track(e, cost_period)
                seg_chosen = endogenous_capex_segment_chosen_from_relevant_period(e)
                big_M_capacity = max_capacity(e)

                if !settings[:ProjectDevelopment]
                    # Cost term for objective function
                    e.aux_new_capacity, e.endog_annualized_investment_cost_times_newcapacity = add_linearized_learning_cost!(
                        model, e, new_capacity(e), seg_chosen, n_segments, big_M_capacity, "vAUXNEWCAP",
                        1.0, capital_recovery_factor(wacc(e), capital_recovery_period(e)))
                else
                    # Project development (aka capital discipline): the deployment share
                    # of capex plus one shadow-capacity cost term per development phase
                    deployment_cost_perc = 1 - de_cost_perc(e) - af_cost_perc(e) - cc_cost_perc(e)
                    e.aux_new_capacity, e.endog_annualized_investment_cost_times_newcapacity = add_linearized_learning_cost!(
                        model, e, new_capacity(e), seg_chosen, n_segments, big_M_capacity, "vAUXNEWCAP",
                        deployment_cost_perc, capital_recovery_factor(wacc(e), capital_recovery_period(e)))
                    e.aux_new_capacity_de, e.endog_annualized_investment_cost_times_newcapacity_de = add_linearized_learning_cost!(
                        model, e, new_de_capacity(e), seg_chosen, n_segments, big_M_capacity, "vAUXNEWCAPDE",
                        de_cost_perc(e), capital_recovery_factor(de_wacc(e), de_cap_recovery(e)))
                    e.aux_new_capacity_af, e.endog_annualized_investment_cost_times_newcapacity_af = add_linearized_learning_cost!(
                        model, e, new_af_capacity(e), seg_chosen, n_segments, big_M_capacity, "vAUXNEWCAPAF",
                        af_cost_perc(e), capital_recovery_factor(af_wacc(e), af_cap_recovery(e)))
                    e.aux_new_capacity_cc, e.endog_annualized_investment_cost_times_newcapacity_cc = add_linearized_learning_cost!(
                        model, e, new_cc_capacity(e), seg_chosen, n_segments, big_M_capacity, "vAUXNEWCAPCC",
                        cc_cost_perc(e), capital_recovery_factor(cc_wacc(e), cc_cap_recovery(e)))
                end

                # For reporting purposes
                e.endog_capex_cost = @expression(model, sum(e.pwl_capex_slopes[k]*seg_chosen[k] for k in 1:n_segments+1))
            end
        end
    end
    return nothing
end

"""
Linearizes `capex(selected segment) * new_cap` with big-M constraints. Adds a new variable aux, such that that `aux[k] = new_cap` for the selected segment k and 0 otherwise.
"""
function add_linearized_learning_cost!(model::Model, e::AbstractEdge, new_cap, seg_chosen,
                                       n_segments::Int, big_M::Float64, prefix::String,
                                       cost_share::Float64, crf::Float64)
    aux = @variable(model, [k in 1:n_segments+1], lower_bound = 0.0, base_name = "$(prefix)_$(id(e))_stage$(period_index(e))_seg_$k")
    # Upper bound on new capacity in a given period
    @constraint(model, [k in 1:n_segments+1], new_cap - aux[k] >= 0)
    # Big M constraints
    @constraint(model, [k in 1:n_segments+1], new_cap - aux[k] <= big_M*(1-seg_chosen[k]))
    @constraint(model, [k in 1:n_segments+1], aux[k] <= big_M*seg_chosen[k])
    # Cost term; coefficient built as (slope * cost_share) * crf
    cost = @expression(model, sum(pwl_capex_slopes(e)[k]*cost_share*aux[k]*crf for k in 1:n_segments+1))
    return aux, cost
end

function learning_n_segments(edges::Vector{AbstractEdge}, learning_tech::String)
    n = unique(n_learning_pwl_segments.(edges))
    length(n) == 1 || error("Learning technology '$learning_tech': all edges must have the same n_learning_pwl_segments, found $(sort(n))")
    n[1] >= 1 || error("Learning technology '$learning_tech': n_learning_pwl_segments must be >= 1, got $(n[1])")
    return n[1]
end

"""
Computes the piece-wise linear learning curve of every learning-technology edge
once. This is done before the model is built.
"""
function prepare_learning_curves!(systems::Vector{System}, settings::NamedTuple)
    for system in systems, learning_tech in settings[:LearningTechnologies]
        learning_tech_edges = get_edges_of_type(system, learning_tech)
        isempty(learning_tech_edges) && continue
        n_segments = learning_n_segments(learning_tech_edges, learning_tech)

        # Cumulative experience (and so the curve breakpoints) is modelled once per
        # technology in add_learning!, so all its edges must share these inputs
        for (name, f) in (("init_cumul_capacity", init_cumul_capacity), ("max_cumul_capacity", max_cumul_capacity))
            vals = unique(f.(learning_tech_edges))
            length(vals) == 1 || error("Learning technology '$learning_tech': all edges must have the same $name, found $(sort(vals))")
        end

        for e in learning_tech_edges
            if max_cumul_capacity(e) == Inf || max_cumul_capacity(e) == -1
                error(string(e.id, " is a learning technology but max cumulative capacity is not specified"))
            end
            # max_capacity is used as the big-M in the learning-cost linearisation
            if max_capacity(e) == Inf || max_capacity(e) == -1
                error(string(e.id, " is a learning technology and max capacity is required for the big-M linearisation, but is not specified"))
            end

            x_points, y_points = compute_pwl_coordinates(n_segments, init_cumul_capacity(e), max_cumul_capacity(e), investment_cost(e), learning_parameter(e))
            x_points[2] > x_points[1] || error(string(e.id, ": init_cumul_capacity must be below the first learning breakpoint (max_cumul_capacity/2^", n_segments - 1, ")"))

            e.pwl_x_points = x_points
            # Learning lags by the construction (CC) duration
            e.learning_delay = cc_duration(e)
            e.pwl_capex_slopes = [investment_cost(e); diff(y_points) ./ diff(x_points)]

            @debug("Learning curve for $(id(e))", x_points, y_points, slopes = e.pwl_capex_slopes)
        end
    end
    return nothing
end

"""
Collects edges that belong to the same learning type
""" 
function get_edges_of_type(system::System, type::String)

    tech_edges = Vector{AbstractEdge}()
    edges = get_edges(system)
    for e in edges 
        if learning_type(e) == type
            push!(tech_edges, e)
        end
    end
    return tech_edges
end

function compute_pwl_coordinates(n_segments::Int, init_cumul_capacity::Float64, max_cumul_capacity::Float64, investment_cost::Float64, learning_parameter::Float64)

    if init_cumul_capacity <= 0
        error("Initial cumulative capacity must be greater than 0 for constructing learning curve")
    end
    if learning_parameter == 1
        error("Learning parameter cannot be 1 for constructing learning curve")
    end

    x_points = zeros(n_segments+1)
    y_points = zeros(n_segments+1)
    
    # Define end points
    x_points[1] = init_cumul_capacity
    x_points[end] = max_cumul_capacity
    
    # X coordinates for piece-wise linear curve
    # X points are spaced exponentially
    for k in 2:n_segments
        x_points[k] = max_cumul_capacity/(2^(n_segments - k +1))
    end

    # Compute Y coordinates
    for k in 1:n_segments+1        
        cost_point = investment_cost*(x_points[k]/init_cumul_capacity)^(-learning_parameter)
        # Estimate cost from fixed capacity points
        y_points[k] = (1/(1-learning_parameter))*(x_points[k]*cost_point-investment_cost*init_cumul_capacity)
    end
    return x_points, y_points
end
