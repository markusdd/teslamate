defmodule TeslaMate.LocationsAddressesTest do
  use TeslaMate.DataCase

  alias TeslaMate.{Locations, Repo}
  alias TeslaMate.Locations.Address

  describe "addresses" do
    @valid_attrs %{
      city: "some city",
      county: "some county",
      country: "some country",
      display_name: "some display_name",
      house_number: "some house_number",
      latitude: 120.5,
      longitude: 120.5,
      name: "some name",
      neighbourhood: "some neighbourhood",
      place_id: 42,
      postcode: "some postcode",
      raw: %{},
      road: "some road",
      state: "some state",
      state_district: "some state_district"
    }
    @update_attrs %{
      city: "some updated city",
      county: "some updated county",
      country: "some updated country",
      display_name: "some updated display_name",
      house_number: "some updated house_number",
      latitude: 456.7,
      longitude: 456.7,
      name: "some updated name",
      neighbourhood: "some updated neighbourhood",
      place_id: 43,
      postcode: "some updated postcode",
      raw: %{},
      road: "some updated road",
      state: "some updated state",
      state_district: "some updated state_district"
    }
    @invalid_attrs %{
      city: nil,
      county: nil,
      country: nil,
      display_name: nil,
      house_number: nil,
      latitude: nil,
      longitude: nil,
      name: nil,
      neighbourhood: nil,
      place_id: nil,
      postcode: nil,
      raw: nil,
      road: nil,
      state: nil,
      state_district: nil
    }

    def address_fixture(attrs \\ %{}) do
      {:ok, address} =
        attrs
        |> Enum.into(@valid_attrs)
        |> Locations.create_address()

      address
    end

    test "create_address/1 with valid data creates a address" do
      assert {:ok, %Address{} = address} = Locations.create_address(@valid_attrs)
      assert address.city == "some city"
      assert address.county == "some county"
      assert address.country == "some country"
      assert address.display_name == "some display_name"
      assert address.house_number == "some house_number"
      assert address.latitude == 120.5
      assert address.longitude == 120.5
      assert address.name == "some name"
      assert address.neighbourhood == "some neighbourhood"
      assert address.place_id == 42
      assert address.postcode == "some postcode"
      assert address.raw == %{}
      assert address.road == "some road"
      assert address.state == "some state"
      assert address.state_district == "some state_district"
    end

    test "create_address/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{} = changeset} = Locations.create_address(@invalid_attrs)

      assert errors_on(changeset) == %{
               display_name: ["can't be blank"],
               latitude: ["can't be blank"],
               longitude: ["can't be blank"],
               place_id: ["can't be blank"],
               raw: ["can't be blank"]
             }
    end

    test "update_address/2 with valid data updates the address" do
      address = address_fixture()
      assert {:ok, %Address{} = address} = Locations.update_address(address, @update_attrs)
      assert address.city == "some updated city"
      assert address.county == "some updated county"
      assert address.country == "some updated country"
      assert address.display_name == "some updated display_name"
      assert address.house_number == "some updated house_number"
      assert address.latitude == 456.7
      assert address.longitude == 456.7
      assert address.name == "some updated name"
      assert address.neighbourhood == "some updated neighbourhood"
      assert address.place_id == 43
      assert address.postcode == "some updated postcode"
      assert address.raw == %{}
      assert address.road == "some updated road"
      assert address.state == "some updated state"
      assert address.state_district == "some updated state_district"
    end

    test "update_address/2 with invalid data returns error changeset" do
      address = address_fixture()
      assert {:error, %Ecto.Changeset{}} = Locations.update_address(address, @invalid_attrs)
    end
  end

  describe "find_address/1 " do
    test "looks up and creates a new address" do
      assert {:ok, %Address{} = address} =
               Locations.find_address(%{latitude: 52.019596, longitude: 8.526318})

      assert address.place_id == 103_619_766
      assert address.city == "Bielefeld"

      assert [^address] = Repo.all(Address)

      assert {:ok, %Address{} = ^address} =
               Locations.find_address(%{latitude: 52.019687, longitude: 8.526041})

      assert [^address] = Repo.all(Address)
    end
  end
end
