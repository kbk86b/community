"""Sky Watch: the nearest recently reported airborne aircraft, from ADSB.lol.

Location is selected in the Tidbyt phone app. Only a coarse location is sent
to the data provider. Data attribution: ADSB.lol, ODbL 1.0.
"""

load("encoding/json.star", "json")
load("http.star", "http")
load("math.star", "math")
load("render.star", "render")
load("schema.star", "schema")
load("time.star", "time")

API_BASE = "https://api.adsb.lol/v2"
CACHE_SECONDS = 60
MAX_REPORT_AGE = 90
DISPLAY_MAX_AGE = 120
BG = "#070d1b"
HEADER = "#0f2433"
CYAN = "#40e4e7"
AMBER = "#ffbc4b"
WHITE = "#ebf6ff"
MUTED = "#98abc4"
RED = "#ff6b6b"

def number(value):
    """Accept finite numbers and short decimal strings without raising errors."""
    if type(value) in ("int", "float"):
        return float(value) if value == value and value > -1e15 and value < 1e15 else None
    if type(value) != "string":
        return None
    text = value.strip()
    if not text or len(text) > 24:
        return None
    unsigned = text[1:] if text[0] in ("-", "+") else text
    if not unsigned or unsigned.count(".") > 1:
        return None
    digits = unsigned.replace(".", "")
    if not digits:
        return None
    for char in digits.elems():
        if char not in "0123456789":
            return None
    return float(text)

def location_from_config(config):
    raw = config.get("location")
    if not raw:
        return None
    location = json.decode(raw, default = None) if type(raw) == "string" else raw
    if type(location) != "dict":
        return None
    lat = number(location.get("lat"))
    lon = number(location.get("lng"))
    if lat == None or lon == None or lat < -90 or lat > 90 or lon < -180 or lon > 180:
        return None
    return (lat, lon)

def radius_from_config(config):
    radius = number(config.get("radius_nm", "10"))
    return int(radius) if radius in (5, 10, 20, 30, 50) else 10

def enabled(config, key, default):
    value = config.get(key)
    return default if value == None else str(value).lower() in ("true", "1")

def coarse_coordinate(value):
    # Truncation to two decimal places avoids sending a precise device location.
    return int(value * 100) / 100.0

def fixed_decimal(value, places = 1):
    scale = 100 if places == 2 else 10
    negative = value < 0
    scaled = int(math.floor((-value if negative else value) * scale + 0.5))
    remainder = str(scaled % scale)
    return ("-" if negative else "") + str(scaled // scale) + "." + "0" * max(0, places - len(remainder)) + remainder

def request_url(location, radius):
    # Two extra NM cover the displacement caused by coarse coordinates. Filter
    # results against the user's selected point and radius after fetching.
    return "%s/lat/%s/lon/%s/dist/%d" % (
        API_BASE,
        fixed_decimal(coarse_coordinate(location[0]), places = 2),
        fixed_decimal(coarse_coordinate(location[1]), places = 2),
        radius + 2,
    )

def distance_nm(lat1, lon1, lat2, lon2):
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    delta_phi = phi2 - phi1
    delta_lon = math.radians(lon2 - lon1)
    sin_phi = math.sin(delta_phi / 2)
    sin_lon = math.sin(delta_lon / 2)
    haversine = sin_phi * sin_phi + math.cos(phi1) * math.cos(phi2) * sin_lon * sin_lon
    return 6880.13 * math.asin(math.sqrt(max(0.0, min(1.0, haversine))))

def payload_age(payload, now):
    stamp = number(payload.get("now"))
    if stamp == None:
        return None

    # ADSB.lol v2 uses milliseconds; accept second-based timestamps as well.
    stamp = stamp / 1000 if stamp > 1e11 else stamp
    age = now - stamp
    return max(0, age) if age >= -30 else None

def closest_aircraft(items, location, radius, snapshot_age):
    winner = None
    closest = radius + 1.0
    for aircraft in items:
        if type(aircraft) != "dict" or aircraft.get("alt_baro") == "ground":
            continue
        altitude = number(aircraft.get("alt_baro"))
        if altitude == None:
            altitude = number(aircraft.get("alt_geom"))
        if altitude == None:
            continue
        seen = number(aircraft.get("seen_pos"))
        lat = number(aircraft.get("lat"))
        lon = number(aircraft.get("lon"))
        if seen == None or seen < 0 or snapshot_age + seen > MAX_REPORT_AGE:
            continue
        if lat == None or lon == None or lat < -90 or lat > 90 or lon < -180 or lon > 180:
            continue
        distance = distance_nm(location[0], location[1], lat, lon)
        if distance <= radius and distance < closest:
            winner = dict(aircraft)
            winner["_distance_nm"] = distance
            closest = distance
    return winner

def label(aircraft):
    for field in ("flight", "r", "hex"):
        value = aircraft.get(field)
        if type(value) == "string" and value.strip():
            return value.strip().upper()
    return "UNKNOWN"

def altitude_text(aircraft):
    altitude = number(aircraft.get("alt_baro"))
    if altitude == None:
        altitude = number(aircraft.get("alt_geom"))
    if altitude == None:
        return "ALT --"
    feet = int(math.floor(altitude / 100 + 0.5)) * 100
    return fixed_decimal(feet / 1000.0) + "KFT" if feet >= 10000 or feet <= -10000 else "%dFT" % feet

def speed_text(aircraft):
    speed = number(aircraft.get("gs"))
    return "%dKT" % int(math.floor(speed + 0.5)) if speed != None and speed >= 0 and speed <= 3000 else "--KT"

def heading_text(aircraft):
    heading = number(aircraft.get("track"))
    if heading == None:
        return "HEADING UNKNOWN"
    heading = heading % 360
    compass = ("N", "NE", "E", "SE", "S", "SW", "W", "NW")
    direction = compass[int((heading + 22.5) // 45) % 8]
    degrees = str(int(math.floor(heading + 0.5)) % 360)
    return "HDG %s %s" % ("0" * (3 - len(degrees)) + degrees, direction)

def short_text(value, fallback, limit = 20):
    return value.strip().upper()[:limit] if type(value) == "string" and value.strip() else fallback

def fitted_text(text, color, font = "tb-8"):
    widget = render.Text(text, color = color, font = font)
    if widget.size()[0] <= 62:
        return widget

    # Long callsigns and registrations remain readable in the smaller font.
    widget = render.Text(text, color = color, font = "tom-thumb")
    if widget.size()[0] <= 62:
        return widget
    return render.Text(text[:14] + ".", color = color, font = "tom-thumb")

def screen(title, primary, middle, bottom, primary_color = AMBER):
    return render.Box(
        width = 64,
        height = 32,
        color = BG,
        child = render.Column(
            children = [
                render.Box(width = 64, height = 7, color = HEADER, child = render.Text(title, font = "CG-pixel-3x5-mono", color = CYAN)),
                render.Box(width = 64, height = 10, child = fitted_text(primary, primary_color)),
                render.Box(width = 64, height = 7, child = fitted_text(middle, WHITE, font = "tom-thumb")),
                render.Box(width = 64, height = 8, child = fitted_text(bottom, CYAN, font = "tom-thumb")),
            ],
        ),
    )

def status_screen(primary, middle, bottom = "", error = False):
    return render.Root(
        child = screen("SKY WATCH", primary, middle, bottom, primary_color = RED if error else AMBER),
        max_age = DISPLAY_MAX_AGE,
    )

def aircraft_display(aircraft, details = True, demo = False):
    plane_type = short_text(aircraft.get("t"), "TYPE ?", limit = 8)
    pages = [screen(
        "SKY WATCH DEMO" if demo else "SKY WATCH",
        label(aircraft),
        "%s %s" % (plane_type, altitude_text(aircraft)),
        "%sNM %s" % (fixed_decimal(aircraft["_distance_nm"]), speed_text(aircraft)),
    )]
    if details:
        pages.append(screen(
            "DEMO DETAILS" if demo else "DETAILS",
            short_text(aircraft.get("r"), "REG UNKNOWN"),
            "TYPE %s" % plane_type,
            heading_text(aircraft),
        ))
    return render.Root(
        child = render.Animation(children = pages),
        delay = 2600,
        max_age = DISPLAY_MAX_AGE,
    )

def display_payload(payload, location, radius, details, hide_empty, now):
    if type(payload) != "dict" or type(payload.get("ac")) != "list":
        return status_screen("DATA ERROR", "TRY AGAIN LATER", error = True)
    age = payload_age(payload, now)
    if age == None or age > MAX_REPORT_AGE:
        return status_screen("FEED STALE", "WAIT FOR UPDATE", error = True)
    aircraft = closest_aircraft(payload["ac"], location, radius, age)
    if aircraft == None:
        return [] if hide_empty else status_screen("NO AIRCRAFT", "WITHIN %d NM" % radius)
    return aircraft_display(aircraft, details = details)

def main(config):
    # Developer-only preview option; never enabled by the phone app schema.
    if enabled(config, "demo", False):
        return aircraft_display({
            "flight": "AAL1234",
            "r": "N38257",
            "t": "B738",
            "gs": 421,
            "track": 270,
            "alt_baro": 26700,
            "_distance_nm": 2.3,
        }, demo = True)
    location = location_from_config(config)
    if location == None:
        return status_screen("SET LOCATION", "IN TIDBYT APP")
    radius = radius_from_config(config)
    response = http.get(
        request_url(location, radius),
        headers = {"Accept": "application/json"},
        ttl_seconds = CACHE_SECONDS,
    )
    if response.status_code != 200:
        return status_screen("DATA ERROR", "HTTP %d" % response.status_code, "TRY AGAIN LATER", error = True)
    payload = json.decode(response.body(), default = None)
    return display_payload(
        payload,
        location,
        radius,
        enabled(config, "details", True),
        enabled(config, "hide_empty", False),
        time.now().unix,
    )

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Location(
                id = "location",
                name = "Location",
                desc = "Search around this location. Only coarse coordinates are sent to ADSB.lol.",
                icon = "locationDot",
            ),
            schema.Dropdown(
                id = "radius_nm",
                name = "Radius",
                desc = "Maximum ground distance in nautical miles.",
                icon = "rulerHorizontal",
                default = "10",
                options = [schema.Option(display = "%d NM" % radius, value = str(radius)) for radius in (5, 10, 20, 30, 50)],
            ),
            schema.Toggle(
                id = "details",
                name = "Aircraft details",
                desc = "Also show registration, aircraft type, and heading.",
                icon = "plane",
                default = True,
            ),
            schema.Toggle(
                id = "hide_empty",
                name = "Hide when empty",
                desc = "Skip this app when no recent airborne aircraft are found.",
                icon = "eyeSlash",
                default = False,
            ),
        ],
    )
