defmodule Ash.Query.Aggregate do
  @moduledoc "Represents an aggregated association value"
  defstruct [
    :name,
    :relationship_path,
    :default_value,
    :resource,
    :query,
    :field,
    :kind,
    :type,
    :constraints,
    :implementation,
    :authorization_filter,
    :load,
    filterable?: true
  ]

  @type t :: %__MODULE__{}

  @kinds [:count, :first, :sum, :list, :max, :min, :avg, :sum, :custom]
  @type kind :: unquote(Enum.reduce(@kinds, &{:|, [], [&1, &2]}))

  alias Ash.Engine.Request
  alias Ash.Error.Query.{NoReadAction, NoSuchRelationship}

  require Ash.Query

  @doc false
  def kinds, do: @kinds

  def new(
        resource,
        name,
        kind,
        relationship,
        query,
        field,
        default \\ nil,
        filterable? \\ true,
        type \\ nil,
        constraints \\ [],
        implementation \\ nil
      ) do
    if kind == :custom && !type do
      raise ArgumentError, "Must supply type when building a `custom` aggregate"
    end

    if kind == :custom && !implementation do
      raise ArgumentError, "Must supply implementation when building a `custom` aggregate"
    end

    attribute_type =
      if field do
        related = Ash.Resource.Info.related(resource, relationship)
        Ash.Resource.Info.field(related, field).type
      end

    default =
      if is_function(default) do
        default.()
      else
        default
      end

    with :ok <- validate_path(resource, List.wrap(relationship)),
         {:ok, type} <- get_type(kind, type, attribute_type),
         {:ok, query} <- validate_query(query) do
      {:ok,
       %__MODULE__{
         name: name,
         resource: resource,
         constraints: constraints,
         default_value: default || default_value(kind),
         relationship_path: List.wrap(relationship),
         implementation: implementation,
         field: field,
         kind: kind,
         type: type,
         query: query,
         filterable?: filterable?
       }}
    end
  end

  defp get_type(:custom, type, _), do: {:ok, type}

  defp get_type(kind, _, attribute_type) do
    kind_to_type(kind, attribute_type)
  end

  defp validate_path(_, []), do: :ok

  defp validate_path(resource, [relationship | rest]) do
    case Ash.Resource.Info.relationship(resource, relationship) do
      nil ->
        {:error, NoSuchRelationship.exception(resource: resource, name: relationship)}

      %{type: :many_to_many, through: through, destination: destination} ->
        cond do
          !Ash.Resource.Info.primary_action(through, :read) ->
            {:error, NoReadAction.exception(resource: through, when: "aggregating")}

          !Ash.Resource.Info.primary_action(destination, :read) ->
            {:error, NoReadAction.exception(resource: destination, when: "aggregating")}

          !Ash.DataLayer.data_layer(through) == Ash.DataLayer.data_layer(resource) ->
            {:error, "Cannot cross data layer boundaries when building an aggregate"}

          true ->
            validate_path(destination, rest)
        end

      relationship ->
        cond do
          !Ash.Resource.Info.primary_action(relationship.destination, :read) ->
            NoReadAction.exception(resource: relationship.destination, when: "aggregating")

          !Ash.DataLayer.data_layer(relationship.destination) ==
              Ash.DataLayer.data_layer(resource) ->
            {:error, "Cannot cross data layer boundaries when building an aggregate"}

          true ->
            validate_path(relationship.destination, rest)
        end
    end
  end

  def default_value(:count), do: 0
  def default_value(:first), do: nil
  def default_value(:sum), do: nil
  def default_value(:max), do: nil
  def default_value(:min), do: nil
  def default_value(:avg), do: nil
  def default_value(:list), do: []
  def default_value(:custom), do: nil

  defp validate_query(nil), do: {:ok, nil}

  defp validate_query(query) do
    cond do
      query.load != [] ->
        {:error, "Cannot load in an aggregate"}

      not is_nil(query.limit) ->
        {:error, "Cannot limit an aggregate (for now)"}

      not (is_nil(query.offset) || query.offset == 0) ->
        {:error, "Cannot offset an aggregate (for now)"}

      true ->
        {:ok, query}
    end
  end

  @doc false
  def kind_to_type({:custom, type}, _attribute_type), do: {:ok, type}
  def kind_to_type(:count, _attribute_type), do: {:ok, Ash.Type.Integer}
  def kind_to_type(kind, nil), do: {:error, "Must provide field type for #{kind}"}
  def kind_to_type(:avg, _attribute_type), do: {:ok, :float}

  def kind_to_type(kind, attribute_type) when kind in [:first, :sum, :max, :min],
    do: {:ok, attribute_type}

  def kind_to_type(:list, attribute_type), do: {:ok, {:array, attribute_type}}
  def kind_to_type(kind, _attribute_type), do: {:error, "Invalid aggregate kind: #{kind}"}

  def requests(
        initial_query,
        can_be_in_query?,
        authorizing?,
        _calculations_in_query,
        request_path
      ) do
    initial_query.aggregates
    |> Map.values()
    |> Enum.map(&{{&1.resource, &1.relationship_path, []}, &1})
    |> Enum.concat(aggregates_from_filter(initial_query))
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.map(fn {key, value} ->
      {key, Enum.uniq_by(Enum.map(value, &elem(&1, 1)), & &1.name)}
    end)
    |> Enum.uniq()
    |> Enum.reduce({[], [], []}, fn {{aggregate_resource, relationship_path, ref_path},
                                     aggregates},
                                    {auth_requests, value_requests, aggregates_in_query} ->
      related = Ash.Resource.Info.related(aggregate_resource, relationship_path)

      can_be_in_query? = can_be_in_query? && ref_path == []

      auth_request =
        if authorizing? do
          auth_request(
            related,
            initial_query,
            relationship_path,
            request_path
          )
        else
          nil
        end

      new_auth_requests =
        if auth_request do
          [auth_request | auth_requests]
        else
          auth_requests
        end

      if can_be_in_query? do
        {new_auth_requests, value_requests, aggregates_in_query ++ aggregates}
      else
        if ref_path == [] do
          request =
            value_request(
              initial_query,
              related,
              relationship_path,
              aggregates,
              auth_request,
              aggregate_resource,
              request_path
            )

          {new_auth_requests, [request | value_requests], aggregates_in_query}
        else
          {new_auth_requests, value_requests, aggregates_in_query}
        end
      end
    end)
  end

  @doc false
  def aggregates_from_filter(query) do
    aggs =
      query.filter
      |> Ash.Filter.used_aggregates(:all, true)
      |> Enum.reject(&(&1.relationship_path == []))
      |> Enum.map(fn ref ->
        {{ref.resource, ref.attribute.relationship_path, ref.attribute.relationship_path},
         ref.attribute}
      end)

    calculations =
      query.filter
      |> Ash.Filter.used_calculations(query.resource)
      |> Enum.flat_map(fn calculation ->
        expression = calculation.module.expression(calculation.opts, calculation.context)

        case Ash.Filter.hydrate_refs(expression, %{
               resource: query.resource,
               aggregates: query.aggregates,
               calculations: query.calculations,
               relationship_path: [],
               public?: false
             }) do
          {:ok, expression} ->
            Ash.Filter.used_aggregates(expression)

          _ ->
            []
        end
      end)
      |> Enum.map(fn aggregate ->
        {{query.resource, aggregate.relationship_path, []}, aggregate}
      end)

    Enum.uniq_by(aggs ++ calculations, &elem(&1, 1).name)
  end

  defp auth_request(related, initial_query, relationship_path, request_path) do
    Request.new(
      resource: related,
      api: initial_query.api,
      async?: false,
      query: Ash.Query.for_read(related, Ash.Resource.Info.primary_action!(related, :read).name),
      path: request_path ++ [:aggregate, relationship_path],
      strict_check_only?: true,
      action: Ash.Resource.Info.primary_action(related, :read),
      name: "authorize aggregate: #{Enum.join(relationship_path, ".")}",
      data: []
    )
  end

  defp value_request(
         initial_query,
         related,
         relationship_path,
         aggregates,
         auth_request,
         aggregate_resource,
         request_path
       ) do
    pkey = Ash.Resource.Info.primary_key(aggregate_resource)

    deps =
      if auth_request do
        [auth_request.path ++ [:authorization_filter], request_path ++ [:fetch, :data]]
      else
        [request_path ++ [:fetch, :data]]
      end

    Request.new(
      resource: aggregate_resource,
      api: initial_query.api,
      query: Ash.Query.for_read(related, Ash.Resource.Info.primary_action!(related, :read).name),
      path: request_path ++ [:aggregate_values, relationship_path],
      action: Ash.Resource.Info.primary_action(aggregate_resource, :read),
      name: "fetch aggregate: #{Enum.join(relationship_path, ".")}",
      data:
        Request.resolve(
          deps,
          fn data ->
            records = get_in(data, request_path ++ [:fetch, :data, :results])

            if records == [] do
              {:ok, %{}}
            else
              initial_query =
                initial_query
                |> Ash.Query.unset([:filter, :sort, :aggregates, :limit, :offset, :select])
                |> Ash.Query.select([])

              query =
                case records do
                  [record] ->
                    filter = record |> Map.take(pkey) |> Enum.to_list()

                    Ash.Query.filter(
                      initial_query,
                      ^filter
                    )

                  records ->
                    filter = [or: Enum.map(records, &Map.take(&1, pkey))]

                    Ash.Query.filter(
                      initial_query,
                      ^filter
                    )
                end

              aggregates =
                if auth_request do
                  case get_in(data, auth_request.path ++ [:authorization_filter]) do
                    nil ->
                      aggregates

                    filter ->
                      Enum.map(aggregates, fn aggregate ->
                        %{
                          aggregate
                          | query: Ash.Query.filter(aggregate.query, ^filter)
                        }
                      end)
                  end
                else
                  aggregates
                end

              with {:ok, data_layer_query} <- Ash.Query.data_layer_query(query),
                   {:ok, data_layer_query} <-
                     add_data_layer_aggregates(
                       data_layer_query,
                       aggregates,
                       initial_query.resource
                     ),
                   {:ok, results} <-
                     Ash.DataLayer.run_query(
                       data_layer_query,
                       query.resource
                     ) do
                loaded_aggregates =
                  aggregates
                  |> Enum.map(& &1.load)
                  |> Enum.reject(&is_nil/1)

                all_aggregates = Enum.map(aggregates, & &1.name)

                aggregate_values =
                  Enum.reduce(results, %{}, fn result, acc ->
                    loaded_aggregate_values = Map.take(result, loaded_aggregates)

                    all_aggregate_values =
                      result.aggregates
                      |> Kernel.||(%{})
                      |> Map.take(all_aggregates)
                      |> Map.merge(loaded_aggregate_values)

                    Map.put(
                      acc,
                      Map.take(result, pkey),
                      all_aggregate_values
                    )
                  end)

                {:ok, aggregate_values}
              else
                {:error, error} ->
                  {:error, error}
              end
            end
          end
        )
    )
  end

  defp add_data_layer_aggregates(data_layer_query, aggregates, aggregate_resource) do
    Ash.DataLayer.add_aggregates(data_layer_query, aggregates, aggregate_resource)
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%{query: nil} = aggregate, opts) do
      container_doc(
        "#" <> to_string(aggregate.kind) <> "<",
        [Enum.join(aggregate.relationship_path, ".")],
        ">",
        opts,
        fn str, _ -> str end,
        separator: ""
      )
    end

    def inspect(%{query: query} = aggregate, opts) do
      field =
        if aggregate.field do
          [aggregate.field]
        else
          []
        end

      container_doc(
        "#" <> to_string(aggregate.kind) <> "<",
        [
          concat([
            Enum.join(aggregate.relationship_path ++ field, "."),
            concat(" from ", to_doc(query, opts))
          ])
        ],
        ">",
        opts,
        fn str, _ -> str end
      )
    end
  end
end
