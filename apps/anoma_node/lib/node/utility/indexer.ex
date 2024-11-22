defmodule Anoma.Node.Utility.Indexer do
  @moduledoc """
  A trivial indexer querying the node tables.
  """

  alias Anoma.Node.Registry
  alias Anoma.Node.Transaction.Storage

  use GenServer
  use TypedStruct

  typedstruct do
    field(:node_id, String.t())
  end

  @type index_type() ::
          :nlfs
          | :cms
          | :unrevealed
          | :resources
          | :height
          | :root
          | :latest_block
          | {:before | :after, non_neg_integer()}

  def start_link(args) do
    args = Keyword.validate!(args, [:node_id])
    name = Registry.via(args[:node_id], __MODULE__)
    GenServer.start_link(__MODULE__, args, name: name)
  end

  def init(args) do
    Process.set_label(__MODULE__)

    state = struct(__MODULE__, Enum.into(args, %{}))
    {:ok, state}
  end

  @spec get(String.t(), index_type) ::
          any()
  def get(node_id, :latest_block) do
    get(node_id, {:after, get_height(node_id) - 1})
  end

  def get(node_id, flag) do
    name = Registry.via(node_id, __MODULE__)
    GenServer.call(name, flag)
  end

  def handle_call(:height, _from, state) do
    {:reply, get_height(state.node_id), state}
  end

  def handle_call(:nlfs, _from, state) do
    {:reply, read_set(:nullifiers, state.node_id), state}
  end

  def handle_call(:cms, _from, state) do
    {:reply, read_set(:commitments, state.node_id), state}
  end

  def handle_call(:unrevealed, _from, state) do
    {:reply, unnulified_coms(state.node_id), state}
  end

  def handle_call(:root, _from, state) do
    {:reply, read_set(:anchor, state.node_id), state}
  end

  def handle_call(:resources, _from, state) do
    res =
      unnulified_coms(state.node_id)
      |> get_jam_info(:commitments)
      |> Stream.map(fn x ->
        {:ok, res} = Nock.Cue.cue(x)
        res
      end)
      |> MapSet.new()

    {:reply, res, state}
  end

  def handle_call({flag, height}, _from, state)
      when flag in [:before, :after] do
    table = Storage.blocks_table(state.node_id)

    op =
      case flag do
        :before -> :<
        :after -> :>
      end

    {:atomic, res} =
      :mnesia.transaction(fn ->
        :mnesia.select(table, [
          {{table, :"$1", :"$2"}, [{op, :"$1", height}], [:"$$"]}
        ])
      end)

    {:reply, res, state}
  end

  @spec unnulified_coms(String.t()) :: MapSet.t(binary())
  defp unnulified_coms(id) do
    nullifiers = read_set(:nullifiers, id) |> get_jam_info(:nullifiers)
    commitments = read_set(:commitments, id) |> get_jam_info(:commitments)

    Stream.reject(commitments, &Enum.member?(nullifiers, &1))
    |> Stream.map(fn x -> "CM_" <> x end)
    |> MapSet.new()
  end

  @spec get_jam_info(MapSet.t(binary()), :commitments | :nullifiers) ::
          Enumerable.t()
  defp get_jam_info(set, :commitments) do
    Stream.map(set, fn <<"CM_", rest::binary>> ->
      rest
    end)
  end

  defp get_jam_info(set, :nullifiers) do
    Stream.map(set, fn <<"NF_", rest::binary>> ->
      rest
    end)
  end

  @spec read_set(:commitments | :nullifiers | :anchor, String.t()) ::
          MapSet.t(binary()) | binary()
  defp read_set(key, id) do
    values = Storage.values_table(id)
    updates = Storage.updates_table(id)

    {:atomic, set} =
      :mnesia.transaction(fn ->
        case :mnesia.read(updates, key) do
          [] ->
            MapSet.new([])

          [{^updates, key, list}] ->
            :mnesia.read(values, {hd(list), key}) |> hd() |> elem(2)
        end
      end)

    set
  end

  @spec get_height(String.t()) :: non_neg_integer()
  defp get_height(node_id) do
    table = Storage.blocks_table(node_id)

    {:atomic, res} =
      :mnesia.transaction(fn ->
        case :mnesia.all_keys(table) |> Enum.sort(:desc) do
          [] -> :absent
          [hd | _tl] -> hd
        end
      end)

    res
  end
end
