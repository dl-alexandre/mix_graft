defmodule ContribTest do
  use ExUnit.Case
  doctest Graft

  test "module loads" do
    assert Code.ensure_loaded?(Graft)
  end
end
