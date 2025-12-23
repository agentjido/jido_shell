defmodule Kodo.Case do
  @moduledoc """
  Test case template for Kodo tests.

  Provides isolated test environments with common setup.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Kodo.Case
    end
  end

  setup do
    :ok
  end
end
