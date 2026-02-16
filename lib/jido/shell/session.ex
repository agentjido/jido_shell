defmodule Jido.Shell.Session do
  @moduledoc """
  High-level API for managing Kodo sessions.

  Sessions are GenServer processes that maintain shell state including
  current working directory, environment variables, and command history.
  """
  alias Jido.Shell.Error
  alias Jido.Shell.Session.State
  alias Jido.Shell.SessionServer

  @type workspace_id :: String.t()

  @doc """
  Starts a new session for the given workspace.

  Returns `{:ok, session_id}` on success.

  ## Options

  - `:session_id` - Custom session ID (default: auto-generated)
  - `:cwd` - Initial working directory (default: "/")
  - `:env` - Initial environment variables (default: %{})
  - `:meta` - Additional metadata (default: %{})

  ## Examples

      iex> {:ok, session_id} = Jido.Shell.Session.start("my_workspace")
      iex> String.starts_with?(session_id, "sess-")
      true
  """
  @spec start(workspace_id(), keyword()) :: {:ok, String.t()} | {:error, Error.t() | term()}
  def start(workspace_id, opts \\ []) do
    with :ok <- validate_workspace_id(workspace_id) do
      session_id = Keyword.get_lazy(opts, :session_id, &generate_id/0)

      child_spec = {
        Jido.Shell.SessionServer,
        Keyword.merge(opts, session_id: session_id, workspace_id: workspace_id)
      }

      case DynamicSupervisor.start_child(Jido.Shell.SessionSupervisor, child_spec) do
        {:ok, _pid} -> {:ok, session_id}
        {:error, _} = error -> error
      end
    end
  end

  @doc """
  Stops a session.
  """
  @spec stop(String.t()) :: :ok | {:error, :not_found | term()}
  def stop(session_id) do
    case lookup(session_id) do
      {:ok, pid} ->
        state =
          case SessionServer.get_state(session_id) do
            {:ok, session_state} -> session_state
            _ -> nil
          end

        case DynamicSupervisor.terminate_child(Jido.Shell.SessionSupervisor, pid) do
          :ok ->
            maybe_cleanup_workspace(state, session_id)
            :ok

          {:error, :not_found} ->
            :ok
        end

      {:error, :not_found} = error ->
        error
    end
  end

  @doc """
  Generates a unique session ID.

  ## Examples

      iex> id = Jido.Shell.Session.generate_id()
      iex> String.starts_with?(id, "sess-")
      true
  """
  @spec generate_id() :: String.t()
  def generate_id do
    "sess-" <> Uniq.UUID.uuid4()
  end

  @doc """
  Returns a via tuple for Registry lookup.

  ## Examples

      iex> Jido.Shell.Session.via_registry("sess-123")
      {:via, Registry, {Jido.Shell.SessionRegistry, "sess-123"}}
  """
  @spec via_registry(String.t()) :: {:via, Registry, {atom(), String.t()}}
  def via_registry(session_id) when is_binary(session_id) do
    {:via, Registry, {Jido.Shell.SessionRegistry, session_id}}
  end

  @doc """
  Looks up a session by ID.

  Returns `{:ok, pid}` if found, `{:error, :not_found}` otherwise.

  ## Examples

      iex> Jido.Shell.Session.lookup("nonexistent")
      {:error, :not_found}
  """
  @spec lookup(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def lookup(session_id) when is_binary(session_id) do
    case Registry.lookup(Jido.Shell.SessionRegistry, session_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Starts a new session with an in-memory VFS mounted at root.

  This is a convenience function for common use cases where you want
  a fully functional session without manually mounting a VFS.

  ## Options

  Same as `start/2`.

  ## Examples

      iex> {:ok, session_id} = Jido.Shell.Session.start_with_vfs("my_workspace")
      iex> String.starts_with?(session_id, "sess-")
      true
  """
  @spec start_with_vfs(workspace_id(), keyword()) :: {:ok, String.t()} | {:error, Error.t() | term()}
  def start_with_vfs(workspace_id, opts \\ []) do
    with :ok <- validate_workspace_id(workspace_id),
         {:ok, mounted_now?} <- ensure_root_mount(workspace_id) do
      opts =
        if mounted_now? do
          Keyword.update(opts, :meta, %{managed_workspace_mount: true}, fn meta ->
            Map.put(meta, :managed_workspace_mount, true)
          end)
        else
          opts
        end

      start(workspace_id, opts)
    end
  end

  @doc """
  Tears down all mounts in a workspace.
  """
  @spec teardown_workspace(workspace_id(), keyword()) :: :ok | {:error, Error.t()}
  def teardown_workspace(workspace_id, opts \\ []) do
    Jido.Shell.VFS.unmount_workspace(workspace_id, opts)
  end

  defp ensure_root_mount(workspace_id) do
    if Jido.Shell.VFS.list_mounts(workspace_id) == [] do
      case Jido.Shell.VFS.mount(
             workspace_id,
             "/",
             Jido.VFS.Adapter.InMemory,
             name: build_vfs_name(workspace_id),
             managed: true
           ) do
        :ok -> {:ok, true}
        {:error, _} = error -> error
      end
    else
      {:ok, false}
    end
  end

  defp build_vfs_name(workspace_id) do
    safe_workspace =
      workspace_id
      |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")
      |> String.slice(0, 48)

    "jido_shell_vfs_#{safe_workspace}_#{System.unique_integer([:positive])}"
  end

  defp maybe_cleanup_workspace(%State{} = state, stopping_session_id) do
    managed_workspace_mount? = Map.get(state.meta, :managed_workspace_mount, false)

    if managed_workspace_mount? and workspace_inactive?(state.workspace_id, stopping_session_id) do
      _ = Jido.Shell.VFS.unmount_workspace(state.workspace_id, managed_only: true)
    end

    :ok
  end

  defp maybe_cleanup_workspace(_state, _stopping_session_id), do: :ok

  defp workspace_inactive?(workspace_id, stopping_session_id) do
    DynamicSupervisor.which_children(Jido.Shell.SessionSupervisor)
    |> Enum.any?(fn
      {_id, pid, :worker, [Jido.Shell.SessionServer]} when is_pid(pid) ->
        case safe_get_state(pid) do
          {:ok, %State{id: session_id, workspace_id: current_workspace}}
          when session_id != stopping_session_id and current_workspace == workspace_id ->
            true

          _ ->
            false
        end

      _ ->
        false
    end)
    |> Kernel.not()
  end

  defp safe_get_state(pid) when is_pid(pid) do
    try do
      case GenServer.call(pid, :get_state, 1_000) do
        {:ok, state} -> {:ok, state}
        _ -> :error
      end
    catch
      :exit, _ -> :error
    end
  end

  defp validate_workspace_id(workspace_id) when is_binary(workspace_id) do
    if String.trim(workspace_id) == "" do
      {:error, Error.session(:invalid_workspace_id, %{workspace_id: workspace_id})}
    else
      :ok
    end
  end

  defp validate_workspace_id(workspace_id),
    do: {:error, Error.session(:invalid_workspace_id, %{workspace_id: workspace_id})}
end
