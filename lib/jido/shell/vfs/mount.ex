defmodule Jido.Shell.VFS.Mount do
  @moduledoc """
  Represents a mounted filesystem at a path.
  """

  defstruct [:path, :adapter, :filesystem, :opts, :child_pid, :ownership]

  @type ownership :: :owned | :shared | :none

  @type t :: %__MODULE__{
          path: String.t(),
          adapter: module(),
          filesystem: Jido.VFS.filesystem(),
          opts: keyword(),
          child_pid: pid() | nil,
          ownership: ownership()
        }

  @doc """
  Creates a new mount from adapter and options.
  """
  @spec new(String.t(), module(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(path, adapter, opts) do
    with {^adapter, _config} = filesystem <- adapter.configure(opts),
         {:ok, child_pid, ownership} <- maybe_start_filesystem(adapter, filesystem) do
      {:ok,
       %__MODULE__{
         path: normalize_path(path),
         adapter: adapter,
         filesystem: filesystem,
         opts: opts,
         child_pid: child_pid,
         ownership: ownership
       }}
    else
      {:error, _} = error -> error
      other -> {:error, {:invalid_adapter_config, other}}
    end
  end

  defp maybe_start_filesystem(adapter, filesystem) do
    if function_exported?(adapter, :starts_processes, 0) and adapter.starts_processes() do
      try do
        case DynamicSupervisor.start_child(Jido.Shell.FilesystemSupervisor, {adapter, filesystem}) do
          {:ok, pid} -> {:ok, pid, :owned}
          {:error, {:already_started, pid}} -> {:ok, pid, :shared}
          {:error, reason} -> {:error, reason}
        end
      rescue
        error ->
          {:error, {:start_child_failed, error}}
      catch
        kind, reason ->
          {:error, {kind, reason}}
      end
    else
      {:ok, nil, :none}
    end
  end

  defp normalize_path("/"), do: "/"
  defp normalize_path(path), do: String.trim_trailing(path, "/")
end
