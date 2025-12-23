defmodule Kodo.VFS.Mount do
  @moduledoc """
  Represents a mounted filesystem at a path.
  """

  defstruct [:path, :adapter, :filesystem, :opts]

  @type t :: %__MODULE__{
          path: String.t(),
          adapter: module(),
          filesystem: Hako.filesystem(),
          opts: keyword()
        }

  @doc """
  Creates a new mount from adapter and options.
  """
  @spec new(String.t(), module(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(path, adapter, opts) do
    case adapter.configure(opts) do
      {^adapter, _config} = filesystem ->
        :ok = maybe_start_filesystem(adapter, filesystem)

        {:ok,
         %__MODULE__{
           path: normalize_path(path),
           adapter: adapter,
           filesystem: filesystem,
           opts: opts
         }}

      {:error, _} = error ->
        error
    end
  end

  defp maybe_start_filesystem(adapter, filesystem) do
    if function_exported?(adapter, :starts_processes, 0) and adapter.starts_processes() do
      case DynamicSupervisor.start_child(Kodo.FilesystemSupervisor, {adapter, filesystem}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp normalize_path("/"), do: "/"
  defp normalize_path(path), do: String.trim_trailing(path, "/")
end
