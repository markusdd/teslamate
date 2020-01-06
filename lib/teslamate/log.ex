defmodule TeslaMate.Log do
  @moduledoc """
  The Log context.
  """

  require Logger

  import TeslaMate.CustomExpressions
  import Ecto.Query, warn: false

  alias __MODULE__.{Car, Drive, Update, ChargingProcess, Charge, Position, State}
  alias TeslaMate.{Repo, Locations, Terrain, Settings}
  alias TeslaMate.Locations.GeoFence
  alias TeslaMate.Settings.{CarSettings, GlobalSettings}

  ## Car

  def list_cars do
    Repo.all(Car)
  end

  def get_car!(id) do
    Repo.get!(Car, id)
  end

  def get_car_by([{_key, nil}]), do: nil
  def get_car_by([{_key, _val}] = opts), do: Repo.get_by(Car, opts)

  def create_car(attrs) do
    %Car{settings: %CarSettings{}}
    |> Car.changeset(attrs)
    |> Repo.insert()
  end

  def create_or_update_car(%Ecto.Changeset{} = changeset) do
    with {:ok, car} <- Repo.insert_or_update(changeset) do
      {:ok, Repo.preload(car, [:settings])}
    end
  end

  def update_car(%Car{} = car, attrs) do
    car
    |> Car.changeset(attrs)
    |> Repo.update()
  end

  def recalculate_efficiencies(%GlobalSettings{} = settings) do
    for car <- list_cars() do
      {:ok, _car} = recalculate_efficiency(car, settings)
    end

    :ok
  end

  ## State

  def start_state(%Car{} = car, state) when not is_nil(state) do
    now = DateTime.utc_now()

    case get_current_state(car) do
      %State{state: ^state} = s ->
        {:ok, s}

      %State{} = s ->
        Repo.transaction(fn ->
          with {:ok, _} <- s |> State.changeset(%{end_date: now}) |> Repo.update(),
               {:ok, new_state} <- create_state(car, %{state: state, start_date: now}) do
            new_state
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      nil ->
        create_state(car, %{state: state, start_date: now})
    end
  end

  def get_current_state(%Car{id: id}) do
    State
    |> where([s], ^id == s.car_id and is_nil(s.end_date))
    |> Repo.one()
  end

  defp create_state(%Car{id: id}, attrs) do
    %State{car_id: id}
    |> State.changeset(attrs)
    |> Repo.insert()
  end

  ## Position

  @terrain (case Mix.env() do
              :test -> TerrainMock
              _____ -> Terrain
            end)

  def insert_position(%Drive{id: id, car_id: car_id}, attrs) do
    elevation = @terrain.get_elevation({attrs.latitude, attrs.longitude})
    attrs = Map.put(attrs, :elevation, elevation)

    %Position{car_id: car_id, drive_id: id}
    |> Position.changeset(attrs)
    |> Repo.insert()
  end

  def insert_position(%Car{id: id}, attrs) do
    elevation = @terrain.get_elevation({attrs.latitude, attrs.longitude})
    attrs = Map.put(attrs, :elevation, elevation)

    %Position{car_id: id}
    |> Position.changeset(attrs)
    |> Repo.insert()
  end

  def get_latest_position do
    Position
    |> order_by(desc: :date)
    |> limit(1)
    |> Repo.one()
  end

  def get_latest_position(%Car{id: id}) do
    Position
    |> where(car_id: ^id)
    |> order_by(desc: :date)
    |> limit(1)
    |> Repo.one()
  end

  def get_positions_without_elevation(min_id \\ 0, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    Position
    |> where([p], p.id > ^min_id and is_nil(p.elevation))
    |> order_by(asc: :id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
    |> case do
      [%Position{id: next} | _] = positions ->
        {Enum.reverse(positions), next}

      [] ->
        {[], nil}
    end
  end

  def update_position(%Position{} = position, attrs) do
    position
    |> Position.changeset(attrs)
    |> Repo.update()
  end

  ## Drive

  def start_drive(%Car{id: id}) do
    %Drive{car_id: id}
    |> Drive.changeset(%{start_date: DateTime.utc_now()})
    |> Repo.insert()
  end

  def close_drive(%Drive{id: id} = drive) do
    drive = Repo.preload(drive, [:car])

    query =
      from p in Position,
        select: %{
          count: count() |> over(:w),
          start_position_id: first_value(p.id) |> over(:w),
          end_position_id: last_value(p.id) |> over(:w),
          outside_temp_avg: avg(p.outside_temp) |> over(:w),
          inside_temp_avg: avg(p.inside_temp) |> over(:w),
          speed_max: max(p.speed) |> over(:w),
          power_max: max(p.power) |> over(:w),
          power_min: min(p.power) |> over(:w),
          power_avg: avg(p.power) |> over(:w),
          end_date: last_value(p.date) |> over(:w),
          start_km: first_value(p.odometer) |> over(:w),
          end_km: last_value(p.odometer) |> over(:w),
          start_ideal_range_km: first_value(p.ideal_battery_range_km) |> over(:w),
          end_ideal_range_km: last_value(p.ideal_battery_range_km) |> over(:w),
          start_rated_range_km: first_value(p.rated_battery_range_km) |> over(:w),
          end_rated_range_km: last_value(p.rated_battery_range_km) |> over(:w),
          distance: (last_value(p.odometer) |> over(:w)) - (first_value(p.odometer) |> over(:w)),
          duration_min:
            fragment(
              "round(extract(epoch from (? - ?)) / 60)::integer",
              last_value(p.date) |> over(:w),
              first_value(p.date) |> over(:w)
            )
        },
        windows: [
          w: [
            order_by:
              fragment("? RANGE BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING", p.date)
          ]
        ],
        where: [drive_id: ^id],
        limit: 1

    case Repo.one(query) do
      %{count: count, distance: distance} = attrs when count >= 2 and distance >= 0.01 ->
        start_pos = Repo.get!(Position, attrs.start_position_id)
        end_pos = Repo.get!(Position, attrs.end_position_id)

        attrs =
          attrs
          |> put_address(:start_address_id, start_pos)
          |> put_address(:end_address_id, end_pos)
          |> put_geofence(:start_geofence_id, start_pos)
          |> put_geofence(:end_geofence_id, end_pos)

        drive
        |> Drive.changeset(attrs)
        |> Repo.update()

      _ ->
        drive
        |> Drive.changeset(%{distance: 0, duration_min: 0})
        |> Repo.delete()
    end
  end

  defp put_address(attrs, key, position) do
    case Locations.find_address(position) do
      {:ok, %Locations.Address{id: id}} ->
        Map.put(attrs, key, id)

      {:error, reason} ->
        Logger.warn("Address not found: #{inspect(reason)}")
        attrs
    end
  end

  defp put_geofence(attrs, key, position) do
    case Locations.find_geofence(position) do
      %GeoFence{id: id} -> Map.put(attrs, key, id)
      nil -> attrs
    end
  end

  ## ChargingProcess

  def get_charging_process!(id) do
    Repo.get!(ChargingProcess, id)
  end

  def update_charging_process(%ChargingProcess{} = charge, attrs) do
    charge
    |> ChargingProcess.changeset(attrs)
    |> Repo.update()
  end

  def start_charging_process(%Car{id: id}, %{latitude: _, longitude: _} = attrs, opts \\ []) do
    position = Map.put(attrs, :car_id, id)

    address_id =
      case Locations.find_address(position) do
        {:ok, %Locations.Address{id: id}} ->
          id

        {:error, reason} ->
          Logger.warn("Address not found: #{inspect(reason)}")
          nil
      end

    geofence_id =
      with %GeoFence{id: id} <- Locations.find_geofence(position) do
        id
      end

    start_date = Keyword.get_lazy(opts, :date, &DateTime.utc_now/0)

    with {:ok, cproc} <-
           %ChargingProcess{car_id: id, address_id: address_id, geofence_id: geofence_id}
           |> ChargingProcess.changeset(%{start_date: start_date, position: position})
           |> Repo.insert() do
      {:ok, Repo.preload(cproc, [:address, :geofence])}
    end
  end

  def insert_charge(%ChargingProcess{id: id}, attrs) do
    %Charge{charging_process_id: id}
    |> Charge.changeset(attrs)
    |> Repo.insert()
  end

  def complete_charging_process(%ChargingProcess{} = charging_process) do
    charging_process = Repo.preload(charging_process, [:car])

    settings = Settings.get_global_settings!()

    stats =
      from(c in Charge,
        select: %{
          start_ideal_range_km: first_value(c.ideal_battery_range_km) |> over(:w),
          end_ideal_range_km: last_value(c.ideal_battery_range_km) |> over(:w),
          start_rated_range_km: first_value(c.rated_battery_range_km) |> over(:w),
          end_rated_range_km: last_value(c.rated_battery_range_km) |> over(:w),
          start_battery_level: first_value(c.battery_level) |> over(:w),
          end_battery_level: last_value(c.battery_level) |> over(:w),
          outside_temp_avg: avg(c.outside_temp) |> over(:w),
          charge_energy_added:
            (last_value(c.charge_energy_added) |> over(:w)) -
              (first_value(c.charge_energy_added) |> over(:w)),
          duration_min:
            duration_min(last_value(c.date) |> over(:w), first_value(c.date) |> over(:w))
        },
        windows: [
          w: [
            order_by:
              fragment("? RANGE BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING", c.date)
          ]
        ],
        where: [charging_process_id: ^charging_process.id],
        limit: 1
      )
      |> Repo.one() || %{}

    charge_energy_used = calculate_energy_used(charging_process)

    attrs =
      stats
      |> Map.put(:end_date, charging_process.end_date || DateTime.utc_now())
      |> Map.put(:charge_energy_used, charge_energy_used)
      |> Map.update(:charge_energy_added, nil, &if(&1 < 0, do: nil, else: &1))

    with {:ok, cproc} <- charging_process |> ChargingProcess.changeset(attrs) |> Repo.update(),
         {:ok, _car} <- recalculate_efficiency(charging_process.car, settings) do
      {:ok, cproc}
    end
  end

  def update_energy_used(%ChargingProcess{} = charging_process) do
    charging_process
    |> ChargingProcess.changeset(%{charge_energy_used: calculate_energy_used(charging_process)})
    |> Repo.update()
  end

  defp calculate_energy_used(%ChargingProcess{id: id} = charging_process) do
    phases = determine_phases(charging_process)

    query =
      from c in Charge,
        join: p in ChargingProcess,
        on: [id: c.charging_process_id],
        select: %{
          energy_used:
            c_if is_nil(c.charger_phases) do
              c.charger_power
            else
              c.charger_actual_current * c.charger_voltage * type(^phases, :float) / 1000.0
            end *
              fragment(
                "EXTRACT(epoch FROM (?))",
                c.date - (lag(c.date) |> over(order_by: c.date))
              ) / 3600
        },
        where: c.charging_process_id == ^id

    from(e in subquery(query),
      select: {sum(e.energy_used)},
      where: e.energy_used > 0
    )
    |> Repo.one()
    |> case do
      {charge_energy_used} -> charge_energy_used
      _ -> nil
    end
  end

  defp determine_phases(%ChargingProcess{id: id}) do
    from(c in Charge,
      join: p in ChargingProcess,
      on: [id: c.charging_process_id],
      select: {
        avg(c.charger_power * 1000 / nullif(c.charger_actual_current * c.charger_voltage, 0)),
        type(avg(c.charger_phases), :integer),
        type(avg(c.charger_voltage), :float),
        count()
      },
      group_by: c.charging_process_id,
      where: c.charging_process_id == ^id
    )
    |> Repo.one()
    |> case do
      {p, r, v, n} when not is_nil(p) and p > 0 and n > 15 ->
        cond do
          r == round(p) ->
            r

          r == 3 and abs(p / :math.sqrt(r) - 1) <= 0.1 ->
            Logger.info("Voltage correction: #{round(v)}V -> #{round(v / :math.sqrt(r))}V")
            :math.sqrt(r)

          abs(round(p) - p) <= 0.3 ->
            Logger.info("Phase correction: #{r} -> #{round(p)}")
            round(p)

          true ->
            nil
        end

      _ ->
        nil
    end
  end

  defp recalculate_efficiency(car, settings, opts \\ [{5, 8}, {4, 5}, {3, 3}, {2, 2}])
  defp recalculate_efficiency(car, _settings, []), do: {:ok, car}

  defp recalculate_efficiency(%Car{id: id} = car, settings, [{precision, threshold} | opts]) do
    {start_range, end_range} =
      case settings do
        %GlobalSettings{preferred_range: :ideal} ->
          {:start_ideal_range_km, :end_ideal_range_km}

        %GlobalSettings{preferred_range: :rated} ->
          {:start_rated_range_km, :end_rated_range_km}
      end

    query =
      from c in ChargingProcess,
        select: {
          round(
            c.charge_energy_added / nullif(field(c, ^end_range) - field(c, ^start_range), 0),
            ^precision
          ),
          count()
        },
        where:
          c.car_id == ^id and c.duration_min > 10 and c.end_battery_level <= 95 and
            not is_nil(field(c, ^end_range)) and not is_nil(field(c, ^start_range)) and
            c.charge_energy_added > 0.0,
        group_by: 1,
        order_by: [desc: 2],
        limit: 1

    case Repo.one(query) do
      {factor, n} when n >= threshold and not is_nil(factor) and factor > 0 ->
        Logger.info("Derived efficiency factor: #{factor * 1000} Wh/km (#{n}x confirmed)",
          car_id: id
        )

        car
        |> Car.changeset(%{efficiency: factor})
        |> Repo.update()

      _ ->
        recalculate_efficiency(car, settings, opts)
    end
  end

  ## Update

  def start_update(%Car{id: id}) do
    %Update{car_id: id}
    |> Update.changeset(%{start_date: DateTime.utc_now()})
    |> Repo.insert()
  end

  def cancel_update(%Update{} = update) do
    Repo.delete(update)
  end

  def finish_update(%Update{} = update, version) do
    update
    |> Update.changeset(%{end_date: DateTime.utc_now(), version: version})
    |> Repo.update()
  end
end
