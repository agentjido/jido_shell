defmodule Jido.Shell.Command.SleepTest do
  use Jido.Shell.Case, async: true

  alias Jido.Shell.ShellSession.State
  alias Jido.Shell.Command.Sleep

  setup do
    {:ok, state} = State.new(%{id: "test", workspace_id: "test"})
    {:ok, state: state}
  end

  describe "run/3" do
    test "sleeps for default 1 second", %{state: state} do
      events =
        capture_events(fn emit ->
          Sleep.run(state, %{args: []}, emit)
        end)

      assert {:output, "Sleeping for 1 seconds...\n"} in events
      assert {:output, "1...\n"} in events
      assert {:output, "Done!\n"} in events
    end

    test "sleeps for specified seconds", %{state: state} do
      start = System.monotonic_time(:millisecond)

      events =
        capture_events(fn emit ->
          Sleep.run(state, %{args: ["2"]}, emit)
        end)

      elapsed = System.monotonic_time(:millisecond) - start
      assert elapsed >= 1900

      assert {:output, "2...\n"} in events
    end

    test "returns ok on success", %{state: state} do
      result = Sleep.run(state, %{args: ["1"]}, fn _ -> :ok end)
      assert {:ok, nil} = result
    end

    test "returns validation error for invalid numeric input", %{state: state} do
      assert {:error, %Jido.Shell.Error{code: {:validation, :invalid_args}}} =
               Sleep.run(state, %{args: ["not-a-number"]}, fn _ -> :ok end)
    end

    test "returns validation error for out-of-range seconds", %{state: state} do
      assert {:error, %Jido.Shell.Error{code: {:validation, :invalid_args}}} =
               Sleep.run(state, %{args: ["999999"]}, fn _ -> :ok end)
    end
  end

  describe "metadata" do
    test "has correct name" do
      assert Sleep.name() == "sleep"
    end

    test "has summary" do
      assert Sleep.summary() == "Sleep for a duration"
    end

    test "has schema" do
      assert Sleep.schema()
    end
  end

  defp capture_events(fun) do
    emit = fn event ->
      send(self(), {:event, event})
      :ok
    end

    fun.(emit)

    receive_all_events([])
  end

  defp receive_all_events(acc) do
    receive do
      {:event, event} -> receive_all_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
