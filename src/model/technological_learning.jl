"""
    add_learning!(system, model, period_idx, settings)

Adds endogenous technological learning to `model` for one period. For each
technology in `settings[:LearningTechnologies]`:

- cumulative experience = `init_cumul_capacity` + all new capacity built so far
  across every edge of that technology (learning is shared by the technology);
- binary variables select the segment of the piece-wise linear learning curve
  that the cumulative experience falls in;
- each edge's investment cost uses the capex of the segment selected
  `learning_delay` periods earlier, linearised with big-M constraints. The
  resulting cost terms (`endog_annualized_investment_cost_times_newcapacity`,
  and its `_de`/`_af`/`_cc` parts under ProjectDevelopment) are used in edge.jl.

The learning curves themselves (`pwl_x_points`, `pwl_capex_slopes`) are inputs
computed beforehand by `prepare_learning_curves!`.
"""
function add_learning!(system::System, model::Model, period_idx::Int, settings::NamedTuple)

    learning_techs = settings[:LearningTechnologies]

    for (tech_idx, learning_tech) in enumerate(learning_techs)

        learning_tech_edges = get_edges_of_type(system, learning_tech)
        isempty(learning_tech_edges) && continue

        # Number of segments of the piece-wise linear learning curve (edge input
        # n_learning_pwl_segments; must be the same for all edges of the technology)
        n_segments = learning_n_segments(learning_tech_edges, learning_tech)

        # Segment of piece-wise linear curve chosen for this learning technology
        endogenous_capex_segment_chosen = @variable(model, [k in 1:n_segments+1], binary=true, base_name = "vBINSEG_LEARNINGTYPE_$(period_idx)_$(tech_idx)_seg")
        @constraint(model, sum(endogenous_capex_segment_chosen[k] for k in 1:n_segments+1) == 1)

        for e in learning_tech_edges

            # Breakpoints and segment slopes of the learning curve, computed once
            # per edge in prepare_learning_curves!
            x_points = pwl_x_points(e)

            e.cumulative_experience = @variable(model, [k in 1:n_segments+1], lower_bound = 0.0, base_name = "vCUMULCAP_$(id(e))_stage$(period_index(e))")

            # Learning is delayed by learning_delay periods (set in prepare_learning_curves!)
            curr_period = period_index(e)
            cost_period = curr_period - learning_delay(e)

            # Cumulative_experience combines existing capacity and all new capacity from modeled region
            @constraint(model, sum(cumulative_experience(e)[k] for k in 1:n_segments+1) == sum(new_capacity_track(f, i) for i=1:curr_period, f in learning_tech_edges) + init_cumul_capacity(e))

            # Determine chosen segment
            # ϵ makes the segment-selection inequality strict. It is a fraction of
            # the first segment's width so it stays above solver tolerances after
            # parameter scaling (init_cumul_capacity/1e6 fell below them, letting
            # the solver pick segment 2 with no new capacity).
            ϵ = 1e-3 * (x_points[2] - x_points[1])
            # Set segment
            @constraint(model, [k in 2:n_segments+1], cumulative_experience(e)[k] >= (x_points[k-1] + ϵ) * endogenous_capex_segment_chosen[k])
            @constraint(model, [k in 1:n_segments+1], cumulative_experience(e)[k] <= x_points[k] * endogenous_capex_segment_chosen[k])

            # Slope reached after building new capacity
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
                big_M_capacity = max_new_capacity(e)*2

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
    add_linearized_learning_cost!(model, e, new_cap, seg_chosen, n_segments, big_M,
                                  prefix, cost_share, crf) -> (aux, cost)

Linearises the learning cost `capex(selected segment) * new_cap`, where the
segment is chosen by the binaries `seg_chosen`. Adds auxiliary variables `aux[k]`
(base name `prefix`) with big-M constraints so that `aux[k] = new_cap` for the
selected segment and 0 otherwise, and returns them together with the annualized
cost expression `sum_k pwl_capex_slopes(e)[k] * cost_share * aux[k] * crf`.
`new_cap` is the edge's new capacity or one of its project-development shadow
capacities; `cost_share` is the share of capex incurred by it.
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

"""
    learning_n_segments(edges, learning_tech) -> Int

Number of segments of the piece-wise linear learning curve for a learning
technology, read from the edges' `n_learning_pwl_segments` input. All edges of
the technology share the segment-choice binaries, so they must use the same value.
"""
function learning_n_segments(edges::Vector{AbstractEdge}, learning_tech::String)
    n = unique(n_learning_pwl_segments.(edges))
    length(n) == 1 || error("Learning technology '$learning_tech': all edges must have the same n_learning_pwl_segments, found $(sort(n))")
    n[1] >= 1 || error("Learning technology '$learning_tech': n_learning_pwl_segments must be >= 1, got $(n[1])")
    return n[1]
end

"""
    prepare_learning_curves!(systems, settings)

Computes the piece-wise linear learning curve of every learning-technology edge
once, before any model is built, and stores it on the edge:

- `pwl_x_points`: cumulative-capacity breakpoints (n_learning_pwl_segments + 1)
- `pwl_capex_slopes`: capex in each segment; segment 1 (no new capacity, no
  learning) is the original `investment_cost`, the others are the slopes of the
  cumulative-cost curve between breakpoints

Also validates the learning inputs. Must run after `compute_annualized_costs!`,
which derives `investment_cost`. Values are assigned (not appended), so calling it
again is safe.
"""
function prepare_learning_curves!(systems::Vector{System}, settings::NamedTuple)
    for system in systems, learning_tech in settings[:LearningTechnologies]
        learning_tech_edges = get_edges_of_type(system, learning_tech)
        isempty(learning_tech_edges) && continue
        n_segments = learning_n_segments(learning_tech_edges, learning_tech)

        for e in learning_tech_edges
            if max_cumul_capacity(e) == Inf || max_cumul_capacity(e) == -1
                error(string(e.id, " is a learning technology but max cumulative capacity is not specified"))
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
