defmodule Jido.Shell.Command.Cat do
  @moduledoc """
  Displays file contents.
  """

  @behaviour Jido.Shell.Command

  @impl true
  def name, do: "cat"

  @impl true
  def summary, do: "Display file contents"

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
        {:error, Jido.Shell.Error.validation("cat", [%{message: "missing file argument"}])}

      files ->
        results =
          Enum.map(files, fn file ->
            path = resolve_path(state.cwd, file)

            case Jido.Shell.VFS.read_file(state.workspace_id, path) do
              {:ok, content} ->
                emit.({:output, content})
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

  defp resolve_path(cwd, path) do
    if String.starts_with?(path, "/") do
      path
    else
      Path.join(cwd, path) |> Path.expand()
    end
  end
end
