defmodule Jido.Shell.Command.Help do
  @moduledoc """
  Shows available commands.
  """

  @behaviour Jido.Shell.Command

  @impl true
  def name, do: "help"

  @impl true
  def summary, do: "Show available commands"

  @impl true
  def schema do
    Zoi.map(%{
      args: Zoi.array(Zoi.string()) |> Zoi.default([])
    })
  end

  @impl true
  def run(_state, args, emit) do
    case args.args do
      [] ->
        output =
          Jido.Shell.Command.Registry.list()
          |> Enum.sort()
          |> Enum.map(fn name ->
            {:ok, module} = Jido.Shell.Command.Registry.lookup(name)
            "  #{name} - #{module.summary()}"
          end)
          |> Enum.join("\n")

        emit.({:output, "Available commands:\n#{output}\n"})
        {:ok, nil}

      [cmd_name | _] ->
        case Jido.Shell.Command.Registry.lookup(cmd_name) do
          {:ok, module} ->
            doc = get_moduledoc(module) || "No detailed help available."

            output = """
            #{cmd_name} - #{module.summary()}

            #{doc}
            """

            emit.({:output, output})
            {:ok, nil}

          {:error, :not_found} ->
            {:error, Jido.Shell.Error.shell(:unknown_command, %{name: cmd_name})}
        end
    end
  end

  defp get_moduledoc(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} -> doc
      {:docs_v1, _, _, _, :none, _, _} -> nil
      _ -> nil
    end
  end
end
