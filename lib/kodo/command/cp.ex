defmodule Kodo.Command.Cp do
  @moduledoc """
  Copy files.

  ## Usage

      cp source dest
  """

  @behaviour Kodo.Command

  @impl true
  def name, do: "cp"

  @impl true
  def summary, do: "Copy files"

  @impl true
  def schema do
    Zoi.map(%{
      args: Zoi.array(Zoi.string()) |> Zoi.default([])
    })
  end

  @impl true
  def run(state, args, emit) do
    case args.args do
      [source, dest] ->
        source_path = resolve_path(state.cwd, source)
        dest_path = resolve_path(state.cwd, dest)

        with {:ok, content} <- Kodo.VFS.read_file(state.workspace_id, source_path),
             :ok <- Kodo.VFS.write_file(state.workspace_id, dest_path, content) do
          emit.({:output, "copied: #{source_path} -> #{dest_path}\n"})
          {:ok, nil}
        end

      _ ->
        {:error, Kodo.Error.validation("cp", [%{message: "usage: cp <source> <dest>"}])}
    end
  end

  defp resolve_path(_cwd, "/" <> _ = path), do: Path.expand(path)
  defp resolve_path(cwd, path), do: Path.join(cwd, path) |> Path.expand()
end
