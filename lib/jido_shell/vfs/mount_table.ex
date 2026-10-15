defmodule Jido.Shell.VFS.MountTable do
  @moduledoc """
  ETS-backed mount table for VFS.
  """

  use GenServer

  alias Jido.Shell.VFS.Mount

  @table :jido_shell_vfs_mounts
  @server __MODULE__

  @doc """
  Initializes the ETS table.
  """
  @spec init() :: :ok
  def init do
    case Process.whereis(@server) do
      nil ->
        case start_link([]) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, _} -> :ok
        end

      _pid ->
        :ok
    end
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: @server)
  end

  @impl true
  def init(:ok) do
    ensure_table()
    :ok
    {:ok, %{}}
  end

  @doc """
  Mounts a filesystem.
  """
  @spec mount(String.t(), String.t(), module(), keyword()) :: :ok | {:error, term()}
  def mount(workspace_id, path, adapter, opts) do
    :ok = init()
    GenServer.call(@server, {:mount, workspace_id, path, adapter, opts})
  end

  @doc """
  Unmounts a filesystem.
  """
  @spec unmount(String.t(), String.t()) :: :ok | {:error, :not_found}
  def unmount(workspace_id, path) do
    :ok = init()
    GenServer.call(@server, {:unmount, workspace_id, path})
  end

  @doc """
  Unmounts all mounts in a workspace.
  """
  @spec unmount_workspace(String.t(), keyword()) :: :ok
  def unmount_workspace(workspace_id, opts \\ []) do
    :ok = init()
    GenServer.call(@server, {:unmount_workspace, workspace_id, opts})
  end

  @doc """
  Lists all mounts for a workspace.
  """
  @spec list(String.t()) :: [Mount.t()]
  def list(workspace_id) do
    :ok = init()

    case :ets.whereis(@table) do
      :undefined ->
        []

      _table ->
        @table
        |> :ets.lookup(workspace_id)
        |> Enum.map(fn {_ws, mount} -> mount end)
        # Longest first for matching
        |> Enum.sort_by(fn m -> -String.length(m.path) end)
    end
  end

  @doc """
  Resolves a path to its mount and relative path.
  """
  @spec resolve(String.t(), String.t()) :: {:ok, Mount.t(), String.t()} | {:error, :no_mount}
  def resolve(workspace_id, path) do
    path = normalize_path(path)
    mounts = list(workspace_id)

    case Enum.find(mounts, fn mount -> path_under_mount?(path, mount.path) end) do
      nil ->
        {:error, :no_mount}

      mount ->
        relative = relative_path(path, mount.path)
        {:ok, mount, relative}
    end
  end

  @doc "Attaches caller-owned storage without starting or stopping it."
  @spec attach(String.t(), String.t(), Jido.VFS.filesystem()) :: :ok | {:error, term()}
  def attach(workspace_id, path, filesystem),
    do: GenServer.call(__MODULE__, {:attach, workspace_id, path, filesystem})

  @doc false
  def track(workspace_id, owner), do: GenServer.call(__MODULE__, {:track, workspace_id, owner})

  @impl true
  def handle_call({:attach, workspace_id, path, {adapter, _} = filesystem}, _from, state) do
    path = normalize_path(path)

    if path_mounted?(workspace_id, path) do
      {:reply, {:error, :path_already_mounted}, state}
    else
      mount = %Mount{path: path, adapter: adapter, filesystem: filesystem, opts: [], child_pid: nil, ownership: :none}
      :ets.insert(@table, {workspace_id, mount})
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:track, workspace_id, owner}, _from, state) do
    ref = Process.monitor(owner)
    {:reply, :ok, Map.put(state, ref, workspace_id)}
  end

  @impl true
  def handle_call({:mount, workspace_id, path, adapter, opts}, _from, state) do
    normalized_path = normalize_path(path)

    reply =
      if path_mounted?(workspace_id, normalized_path) do
        {:error, :path_already_mounted}
      else
        case Mount.new(normalized_path, adapter, opts) do
          {:ok, mount} ->
            :ets.insert(@table, {workspace_id, mount})
            :ok

          {:error, _} = error ->
            error
        end
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:unmount, workspace_id, path}, _from, state) do
    normalized = normalize_path(path)
    mounts = list(workspace_id)

    reply =
      case Enum.find(mounts, fn m -> m.path == normalized end) do
        nil ->
          {:error, :not_found}

        mount ->
          :ets.delete_object(@table, {workspace_id, mount})
          maybe_stop_filesystem(mount)
          :ok
      end

    state = retire_monitor_if_empty(state, workspace_id)
    {:reply, reply, state}
  end

  @impl true
  def handle_call({:unmount_workspace, workspace_id, opts}, _from, state) do
    managed_only? = Keyword.get(opts, :managed_only, false)

    workspace_id
    |> list()
    |> Enum.filter(fn mount ->
      not managed_only? or Keyword.get(mount.opts, :managed, false)
    end)
    |> Enum.each(fn mount ->
      :ets.delete_object(@table, {workspace_id, mount})
      maybe_stop_filesystem(mount)
    end)

    state = retire_monitor_if_empty(state, workspace_id)

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state, ref) do
      {nil, rest} ->
        {:noreply, rest}

      {workspace_id, rest} ->
        # Attached mounts borrow storage; only remove routing entries.
        :ets.delete(@table, workspace_id)
        {:noreply, rest}
    end
  end

  defp retire_monitor_if_empty(state, workspace_id) do
    if list(workspace_id) == [] do
      Enum.reduce(state, state, fn {ref, tracked_id}, acc ->
        if tracked_id == workspace_id do
          Process.demonitor(ref, [:flush])
          Map.delete(acc, ref)
        else
          acc
        end
      end)
    else
      state
    end
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :protected, :bag, read_concurrency: true])
    end
  end

  defp path_under_mount?(_path, "/"), do: true

  defp path_under_mount?(path, mount_path) do
    String.starts_with?(path, mount_path <> "/") or path == mount_path
  end

  defp relative_path(path, "/") do
    String.trim_leading(path, "/")
    |> case do
      "" -> "."
      p -> p
    end
  end

  defp relative_path(path, mount_path) when path == mount_path, do: "."

  defp relative_path(path, mount_path) do
    String.trim_leading(path, mount_path <> "/")
  end

  defp path_mounted?(workspace_id, normalized_path) do
    Enum.any?(list(workspace_id), fn mount ->
      mount.path == normalized_path
    end)
  end

  defp maybe_stop_filesystem(%Mount{ownership: :owned, child_pid: pid}) when is_pid(pid) do
    case DynamicSupervisor.terminate_child(Jido.Shell.FilesystemSupervisor, pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp maybe_stop_filesystem(_mount), do: :ok

  defp normalize_path("/"), do: "/"
  defp normalize_path(path), do: String.trim_trailing(path, "/")
end
