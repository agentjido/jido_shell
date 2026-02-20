defmodule Jido.Shell.Command.Mkdir do
  @moduledoc """
  Creates directories.

  ## Usage

      mkdir <directory> [directory...]
  """

  @behaviour Jido.Shell.Command

  @impl true
  def name, do: "mkdir"

  @impl true
  def summary, do: "Create directories"

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
        {:error, Jido.Shell.Error.validation("mkdir", [%{message: "missing directory argument"}])}

      dirs ->
        results =
          Enum.map(dirs, fn dir ->
            path = resolve_path(state.cwd, dir)

            case Jido.Shell.VFS.mkdir(state.workspace_id, path) do
              :ok ->
                emit.({:output, "created: #{path}\n"})
                :ok

              {:error, _} = error ->
                error
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
