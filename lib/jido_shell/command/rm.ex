defmodule Jido.Shell.Command.Rm do
  @moduledoc """
  Remove files.

  ## Usage

      rm file1 [file2 ...]
  """

  @behaviour Jido.Shell.Command

  @impl true
  def name, do: "rm"

  @impl true
  def summary, do: "Remove files"

  @impl true
  def schema do
    Zoi.map(%{
      args: Zoi.array(Zoi.string()) |> Zoi.default([])
    })
  end

  @impl true
  def run(state, args, emit) do
    case args.args do
      [] ->
        {:error, Jido.Shell.Error.validation("rm", [%{message: "missing file argument"}])}

      files ->
        results =
          Enum.map(files, fn file ->
            path = resolve_path(state.cwd, file)

            if Jido.Shell.VFS.exists?(state.workspace_id, path) do
              case Jido.Shell.VFS.delete(state.workspace_id, path) do
                :ok ->
                  emit.({:output, "removed: #{path}\n"})
                  :ok

                {:error, _} = error ->
                  error
              end
            else
              {:error, Jido.Shell.Error.vfs(:not_found, path)}
            end
          end)

        case Enum.find(results, &match?({:error, _}, &1)) do
          nil -> {:ok, nil}
          error -> error
        end
    end
  end

  defp resolve_path(_cwd, "/" <> _ = path), do: Path.expand(path)
  defp resolve_path(cwd, path), do: Path.join(cwd, path) |> Path.expand()
end
