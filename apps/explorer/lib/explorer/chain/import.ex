defmodule Explorer.Chain.Import do
  @moduledoc """
  Bulk importing of data into `Explorer.Repo`
  """

  alias Ecto.Changeset
  alias Explorer.Account.Notify
  alias Explorer.Chain.Events.Publisher
  alias Explorer.Chain.{Block, Import}
  alias Explorer.Chain.Import.Stage
  alias Explorer.Repo

  require Logger

  @stages [
    [
      Import.Stage.Blocks
    ],
    [
      Import.Stage.Main
    ],
    [
      Import.Stage.BlockTransactionReferencing,
      Import.Stage.TokenReferencing,
      Import.Stage.TokenInstances,
      Import.Stage.Logs,
      Import.Stage.InternalTransactions,
      Import.Stage.ChainTypeSpecific
    ]
  ]

  @all_runners Enum.flat_map(@stages, fn stage_batch ->
                 Enum.flat_map(stage_batch, fn stage -> stage.all_runners() end)
               end)

  quoted_runner_option_value =
    quote do
      Import.Runner.options()
    end

  quoted_runner_options =
    for runner <- @all_runners do
      quoted_key =
        quote do
          optional(unquote(runner.option_key()))
        end

      {quoted_key, quoted_runner_option_value}
    end

  @type all_options :: %{
          optional(:broadcast) => atom,
          optional(:timeout) => timeout,
          unquote_splicing(quoted_runner_options)
        }

  quoted_runner_imported =
    for runner <- @all_runners do
      quoted_key =
        quote do
          optional(unquote(runner.option_key()))
        end

      quoted_value =
        quote do
          unquote(runner).imported()
        end

      {quoted_key, quoted_value}
    end

  @type all_result ::
          {:ok, %{unquote_splicing(quoted_runner_imported)}}
          | {:error, [Changeset.t()] | :timeout}
          | {:error, step :: Ecto.Multi.name(), failed_value :: any(),
             changes_so_far :: %{optional(Ecto.Multi.name()) => any()}}

  @type timestamps :: %{inserted_at: DateTime.t(), updated_at: DateTime.t()}

  # milliseconds
  @transaction_timeout :timer.minutes(4)

  @max_import_concurrency 10

  @imported_table_rows @all_runners
                       |> Stream.map(&Map.put(&1.imported_table_row(), :key, &1.option_key()))
                       |> Enum.map_join("\n", fn %{
                                                   key: key,
                                                   value_type: value_type,
                                                   value_description: value_description
                                                 } ->
                         "| `#{inspect(key)}` | `#{value_type}` | #{value_description} |"
                       end)
  @runner_options_doc Enum.map_join(@all_runners, fn runner ->
                        ecto_schema_module = runner.ecto_schema_module()

                        """
                          * `#{runner.option_key() |> inspect()}`
                            * `:on_conflict` - what to do if a conflict occurs with a pre-existing row: `:nothing`, `:replace_all`, or an
                              `t:Ecto.Query.t/0` to update specific columns.
                            * `:params` - `list` of params for changeset function in `#{ecto_schema_module}`.
                            * `:with` - changeset function to use in `#{ecto_schema_module}`.  Default to `:changeset`.
                            * `:timeout` - the timeout for inserting each batch of changes from `:params`.
                              Defaults to `#{runner.timeout()}` milliseconds.
                        """
                      end)

  @doc """
  Bulk insert all data stored in the `Explorer`.

  The import returns the unique key(s) for each type of record inserted.

  | Key | Value Type | Value Description |
  |-----|------------|-------------------|
  #{@imported_table_rows}

  The params for each key are validated using the corresponding `Ecto.Schema` module's `changeset/2` function.  If there
  are errors, they are returned in `Ecto.Changeset.t`s, so that the original, invalid value can be reconstructed for any
  error messages.

  Because there are multiple processes potentially writing to the same tables at the same time,
  `c:Ecto.Repo.insert_all/2`'s
  [`:conflict_target` and `:on_conflict` options](https://hexdocs.pm/ecto/Ecto.Repo.html#c:insert_all/3-options) are
  used to perform [upserts](https://hexdocs.pm/ecto/Ecto.Repo.html#c:insert_all/3-upserts) on all tables, so that
  a pre-existing unique key will not trigger a failure, but instead replace or otherwise update the row.

  ## Data Notifications

  On successful inserts, processes interested in certain domains of data will be notified
  that new data has been inserted. See `Explorer.Chain.Events.Subscriber.to_events/2` for more information.

  ## Options

    * `:broadcast` - Boolean flag indicating whether or not to broadcast the event.
    * `:timeout` - the timeout for the whole `c:Ecto.Repo.transaction/0` call.  Defaults to `#{@transaction_timeout}`
      milliseconds.
  #{@runner_options_doc}
  """
  # @spec all(all_options()) :: all_result()
  def all(options) when is_map(options) do
    with {:ok, runner_options_pairs} <- validate_options(options),
         {:ok, valid_runner_option_pairs} <- validate_runner_options_pairs(runner_options_pairs),
         {:ok, runner_to_changes_list} <- runner_to_changes_list(valid_runner_option_pairs),
         {:ok, data} <- insert_runner_to_changes_list(runner_to_changes_list, options) do
      Notify.async(data[:transactions])
      Publisher.broadcast(data, Map.get(options, :broadcast, false))
      {:ok, data}
    end
  end

  @doc """
  Prepares a bulk import transaction without executing it.

  This function follows the same validation steps as `all/1` but instead of executing the transaction,
  it returns the prepared `Ecto.Multi` struct. This allows the caller to compose the transaction with
  additional operations before executing it.

  ## Parameters

  - `runners`: List of runner modules to prepare the multi for
  - `options`: The import options map (same structure as in `all/1`)

  ## Returns

  - `{:ok, multi}` - The prepared transaction that can be executed later
  - `{:error, [Changeset.t()]}` - Validation errors for the provided options
  - `{:error, {:unknown_options, map()}}` - Unknown options were provided
  """
  @spec all_single_multi([module()], all_options()) ::
          {:ok, Ecto.Multi.t()}
          | {:error, [Changeset.t()]}
          | {:error, {:unknown_options, map()}}
  def all_single_multi(runners, options) do
    with {:ok, runner_options_pairs} <- validate_options(options),
         {:ok, valid_runner_option_pairs} <- validate_runner_options_pairs(runner_options_pairs),
         {:ok, runner_to_changes_list} <- runner_to_changes_list(valid_runner_option_pairs) do
      timestamps = timestamps()
      full_options = Map.put(options, :timestamps, timestamps)
      {multi, _remaining_runner_to_changes_list} = Stage.single_multi(runners, runner_to_changes_list, full_options)
      {:ok, multi}
    end
  end

  defp configured_runners do
    # in order so that foreign keys are inserted before being referenced
    Enum.flat_map(@stages, fn stage_batch ->
      Enum.flat_map(stage_batch, fn stage -> stage.runners() end)
    end)
  end

  defp runner_to_changes_list(runner_options_pairs) when is_list(runner_options_pairs) do
    runner_options_pairs
    |> Stream.map(fn {runner, options} -> runner_changes_list(runner, options) end)
    |> Enum.reduce({:ok, %{}}, fn
      {:ok, {runner, changes_list}}, {:ok, acc_runner_to_changes_list} ->
        {:ok, Map.put(acc_runner_to_changes_list, runner, changes_list)}

      {:ok, _}, {:error, _} = error ->
        error

      {:error, _} = error, {:ok, _} ->
        error

      {:error, runner_changesets}, {:error, acc_changesets} ->
        {:error, acc_changesets ++ runner_changesets}
    end)
  end

  defp runner_changes_list(runner, %{params: params} = options) do
    ecto_schema_module = runner.ecto_schema_module()
    changeset_function_name = Map.get(options, :with, :changeset)
    struct = ecto_schema_module.__struct__()

    params
    |> Stream.map(&apply(ecto_schema_module, changeset_function_name, [struct, &1]))
    |> Enum.reduce({:ok, []}, fn
      changeset = %Changeset{valid?: false}, {:ok, _} ->
        {:error, [changeset]}

      changeset = %Changeset{valid?: false}, {:error, acc_changesets} ->
        {:error, [changeset | acc_changesets]}

      %Changeset{changes: changes, valid?: true}, {:ok, acc_changes} ->
        {:ok, [changes | acc_changes]}

      %Changeset{valid?: true}, {:error, _} = error ->
        error

      :ignore, error ->
        {:error, error}
    end)
    |> case do
      {:ok, changes} -> {:ok, {runner, changes}}
      {:error, _} = error -> error
    end
  end

  @global_options ~w(broadcast timeout)a

  defp validate_options(options) when is_map(options) do
    local_options = Map.drop(options, @global_options)

    {reverse_runner_options_pairs, unknown_options} =
      Enum.reduce(configured_runners(), {[], local_options}, fn runner,
                                                                {acc_runner_options_pairs, unknown_options} = acc ->
        option_key = runner.option_key()

        case local_options do
          %{^option_key => option_value} ->
            {[{runner, option_value} | acc_runner_options_pairs], Map.delete(unknown_options, option_key)}

          _ ->
            acc
        end
      end)

    case Enum.empty?(unknown_options) do
      true -> {:ok, Enum.reverse(reverse_runner_options_pairs)}
      false -> {:error, {:unknown_options, unknown_options}}
    end
  end

  defp validate_runner_options_pairs(runner_options_pairs) when is_list(runner_options_pairs) do
    {status, reversed} =
      runner_options_pairs
      |> Stream.map(fn {runner, options} -> validate_runner_options(runner, options) end)
      |> Enum.reduce({:ok, []}, fn
        :ignore, acc ->
          acc

        {:ok, valid_runner_option_pair}, {:ok, valid_runner_options_pairs} ->
          {:ok, [valid_runner_option_pair | valid_runner_options_pairs]}

        {:ok, _}, {:error, _} = error ->
          error

        {:error, reason}, {:ok, _} ->
          {:error, [reason]}

        {:error, reason}, {:error, reasons} ->
          {:error, [reason | reasons]}
      end)

    {status, Enum.reverse(reversed)}
  end

  defp validate_runner_options(runner, options) when is_map(options) do
    option_key = runner.option_key()

    runner_specific_options =
      if Map.has_key?(Enum.into(runner.__info__(:functions), %{}), :runner_specific_options) do
        runner.runner_specific_options()
      else
        []
      end

    case {validate_runner_option_params_required(option_key, options),
          validate_runner_options_known(option_key, options, runner_specific_options)} do
      {:ignore, :ok} -> :ignore
      {:ignore, {:error, _} = error} -> error
      {:ok, :ok} -> {:ok, {runner, options}}
      {:ok, {:error, _} = error} -> error
      {{:error, reason}, :ok} -> {:error, [reason]}
      {{:error, reason}, {:error, reasons}} -> {:error, [reason | reasons]}
    end
  end

  defp validate_runner_option_params_required(_, %{params: params}) do
    case Enum.empty?(params) do
      false -> :ok
      true -> :ignore
    end
  end

  defp validate_runner_option_params_required(runner_option_key, _),
    do: {:error, {:required, [runner_option_key, :params]}}

  @local_options ~w(on_conflict params with timeout)a

  defp validate_runner_options_known(runner_option_key, options, runner_specific_options) do
    base_unknown_option_keys = Map.keys(options) -- @local_options
    unknown_option_keys = base_unknown_option_keys -- runner_specific_options

    if Enum.empty?(unknown_option_keys) do
      :ok
    else
      reasons = Enum.map(unknown_option_keys, &{:unknown, [runner_option_key, &1]})

      {:error, reasons}
    end
  end

  defp runner_to_changes_list_to_multis(runner_to_changes_list, options)
       when is_map(runner_to_changes_list) and is_map(options) do
    timestamps = timestamps()
    full_options = Map.put(options, :timestamps, timestamps)

    {multis_batches, final_runner_to_changes_list} =
      Enum.map_reduce(@stages, runner_to_changes_list, fn stage_batch, remaining_runner_to_changes_list ->
        Enum.flat_map_reduce(stage_batch, remaining_runner_to_changes_list, fn stage, inner_remaining_list ->
          stage.multis(inner_remaining_list, full_options)
        end)
      end)

    unless Enum.empty?(final_runner_to_changes_list) do
      raise ArgumentError,
            "No stages consumed the following runners: #{final_runner_to_changes_list |> Map.keys() |> inspect()}"
    end

    multis_batches
  end

  def insert_changes_list(repo, changes_list, options) when is_atom(repo) and is_list(changes_list) do
    ecto_schema_module = Keyword.fetch!(options, :for)

    timestamped_changes_list = timestamp_changes_list(changes_list, Keyword.fetch!(options, :timestamps))

    {_, inserted} =
      repo.safe_insert_all(
        ecto_schema_module,
        timestamped_changes_list,
        Keyword.drop(options, [:for, :fields_to_update])
      )

    {:ok, inserted}
  end

  defp timestamp_changes_list(changes_list, timestamps) when is_list(changes_list) do
    Enum.map(changes_list, &timestamp_params(&1, timestamps))
  end

  defp timestamp_params(changes, timestamps) when is_map(changes) do
    Map.merge(changes, timestamps)
  end

  defp insert_runner_to_changes_list(runner_to_changes_list, options) when is_map(runner_to_changes_list) do
    runner_to_changes_list
    |> runner_to_changes_list_to_multis(options)
    |> logged_import(options)
    |> case do
      {:ok, result} ->
        {:ok, result}

      error ->
        handle_partially_imported_blocks(options)
        error
    end
  rescue
    exception ->
      handle_partially_imported_blocks(options)
      reraise exception, __STACKTRACE__
  end

  defp logged_import(multis_batches, options) when is_list(multis_batches) and is_map(options) do
    import_id = :erlang.unique_integer([:positive])

    Explorer.Logger.metadata(fn -> import_batch_transactions(multis_batches, options) end, import_id: import_id)
  end

  defp import_batch_transactions(multis_batches, options) when is_list(multis_batches) and is_map(options) do
    Enum.reduce_while(multis_batches, {:ok, %{}}, fn multis, {:ok, acc_changes} ->
      multis
      |> run_parallel_multis(options)
      |> handle_task_results(acc_changes)
      |> case do
        {:ok, changes} -> {:cont, {:ok, changes}}
        error -> {:halt, error}
      end
    end)
  rescue
    exception in DBConnection.ConnectionError ->
      case Exception.message(exception) do
        "tcp recv: closed" <> _ -> {:error, :timeout}
        _ -> reraise exception, __STACKTRACE__
      end
  end

  defp run_parallel_multis(multis, options) do
    Task.async_stream(multis, fn multi -> import_transaction(multi, options) end,
      timeout: :infinity,
      max_concurrency: @max_import_concurrency
    )
  end

  defp import_transaction(multi, options) when is_map(options) do
    Repo.logged_transaction(multi, timeout: Map.get(options, :timeout, @transaction_timeout))
  rescue
    exception -> {:exception, exception, __STACKTRACE__}
  end

  defp handle_task_results(task_results, acc_changes) do
    Enum.reduce_while(task_results, {:ok, acc_changes}, fn task_result, {:ok, acc_changes_inner} ->
      case task_result do
        {:ok, {:ok, changes}} -> {:cont, {:ok, Map.merge(acc_changes_inner, changes)}}
        {:ok, {:exception, exception, stacktrace}} -> reraise exception, stacktrace
        {:ok, error} -> {:halt, error}
        {:exit, reason} -> {:halt, reason}
        nil -> {:halt, :timeout}
      end
    end)
  end

  defp handle_partially_imported_blocks(%{blocks: %{params: blocks_params}}) do
    block_numbers = Enum.map(blocks_params, & &1.number)
    Block.set_refetch_needed(block_numbers)
    Import.Runner.Blocks.process_blocks_consensus(blocks_params)

    Logger.warning("Set refetch_needed for partially imported block because of error: #{inspect(block_numbers)}")
  end

  defp handle_partially_imported_blocks(_options), do: :ok

  @spec timestamps() :: timestamps
  def timestamps do
    now = DateTime.utc_now()
    %{inserted_at: now, updated_at: now}
  end
end
