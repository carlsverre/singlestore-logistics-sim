package simulator

import (
	"os"
	"time"

	"gonum.org/v1/gonum/stat/distuv"
	"gopkg.in/yaml.v2"
)

type DatabaseConfig struct {
	Host     string `yaml:"host"`
	Port     int    `yaml:"port"`
	Username string `yaml:"username"`
	Password string `yaml:"password"`
	Database string `yaml:"database"`
}

type NormalDistribution struct {
	Avg    float64 `yaml:"avg"`
	Stddev float64 `yaml:"stddev"`
}

func (n *NormalDistribution) ToDist() *distuv.Normal {
	return &distuv.Normal{
		Mu:    n.Avg,
		Sigma: n.Stddev,
	}
}

type Config struct {
	Verbose int `yaml:"verbose"`

	StartTime    time.Time     `yaml:"start_time"`
	TickDuration time.Duration `yaml:"tick_duration"`

	MaxPackages  int `yaml:"max_packages"`
	MaxDelivered int `yaml:"max_delivered"`

	PackagesPerTick NormalDistribution `yaml:"packages_per_tick"`
	HoursAtRest     NormalDistribution `yaml:"hours_at_rest"`

	// ProbabilityExpress measures the probability that a package is shipped express
	// should be a value between 0 and 1
	ProbabilityExpress float64 `yaml:"probability_express"`

	// minimum shipping distance in metres
	// we will only deal with packages going at least this far
	// (in terms of linear distance between origin and destination)
	MinShippingDistanceMetres float64 `yaml:"min_shipping_distance_metres"`

	// minimum air freight distance in metres
	// we will send packages by air if the segment distance is larger than this value
	MinAirFreightDistanceMetres float64 `yaml:"min_air_freight_distance_metres"`

	// avg land speed in metres per hour
	AvgLandSpeedMetreHours float64 `yaml:"avg_land_speed_metre_hours"`

	// avg air freight speed in metres per hour
	AvgAirSpeedMetreHours float64 `yaml:"avg_air_speed_metre_hours"`

	Database DatabaseConfig `yaml:"database"`
}

func ParseConfigs(filenames []string) (*Config, error) {
	// initialize with default values
	cfg := Config{
		StartTime:    time.Now(),
		TickDuration: time.Hour,
	}

	for _, filename := range filenames {
		f, err := os.Open(filename)
		if err != nil {
			return nil, err
		}
		defer f.Close()

		decoder := yaml.NewDecoder(f)
		err = decoder.Decode(&cfg)
		if err != nil {
			return nil, err
		}
	}

	return &cfg, nil
}
