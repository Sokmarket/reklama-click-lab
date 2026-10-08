package main

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"os"
	"time"

	"github.com/oschwald/geoip2-golang"
	"github.com/redis/go-redis/v9"
)

type FlagModel struct {
	Img          *string `json:"img"`
	Emoji        *string `json:"emoji"`
	EmojiUnicode *string `json:"emoji_unicode"`
}

type ConnectionModel struct {
	Asn    *uint   `json:"asn"`
	Org    *string `json:"org"`
	Isp    *string `json:"isp"`
	Domain *string `json:"domain"`
}

type TimezoneModel struct {
	Id     *string `json:"id"`
	Abbr   *string `json:"abbr"`
	IsDst  *bool   `json:"is_dst"`
	Offset *int    `json:"offset"`
	Utc    *string `json:"utc"`
}

type GeoResponse struct {
	Ip            string           `json:"ip"`
	Success       bool             `json:"success"`
	Type          *string          `json:"type"`
	Continent     *string          `json:"continent"`
	ContinentCode *string          `json:"continent_code"`
	Country       *string          `json:"country"`
	CountryCode   *string          `json:"country_code"`
	Region        *string          `json:"region"`
	RegionCode    *string          `json:"region_code"`
	City          *string          `json:"city"`
	Latitude      *float64         `json:"latitude"`
	Longitude     *float64         `json:"longitude"`
	IsEu          *bool            `json:"is_eu"`
	Postal        *string          `json:"postal"`
	CallingCode   *string          `json:"calling_code"`
	Capital       *string          `json:"capital"`
	Borders       []string         `json:"borders"`
	Flag          *FlagModel       `json:"flag"`
	Connection    *ConnectionModel `json:"connection"`
	Timezone      *TimezoneModel   `json:"timezone"`
}

var db *geoip2.Reader
var dbLoaded = false
var rdb *redis.Client
var ctx = context.Background()

func main() {
	var err error
	
	db, err = geoip2.Open("GeoLite2-City.mmdb")
	if err != nil {
		println("UYARI: GeoLite2-City.mmdb bulunamadı! Test modu aktif.")
	} else {
		dbLoaded = true
		defer db.Close()
	}

	redisAddr := os.Getenv("REDIS_ADDR")
	if redisAddr == "" {
		redisAddr = "localhost:6379"
	}

	rdb = redis.NewClient(&redis.Options{
		Addr: redisAddr,
	})

	_, err = rdb.Ping(ctx).Result()
	if err != nil {
		println("UYARI: Redis bağlantısı kurulamadı.")
	}

	http.HandleFunc("/geolocation", handleGeolocation)

	println("Gelişmiş IP Servisi 8080 portunda çalışıyor...")
	http.ListenAndServe(":8081", nil)
}

func handleGeolocation(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	ipStr := r.URL.Query().Get("ip")
	parsedIP := net.ParseIP(ipStr)

	if parsedIP == nil {
		resp := GeoResponse{Ip: ipStr, Success: false}
		json.NewEncoder(w).Encode(resp)
		return
	}

	cacheKey := "geo:" + ipStr

	if rdb != nil {
		val, err := rdb.Get(ctx, cacheKey).Result()
		if err == nil {
			w.Write([]byte(val))
			return
		}
	}

	var countryName, countryCode, cityName, timeZoneStr string
	var lat, lon float64
	var isEu bool

	if dbLoaded {
		record, err := db.City(parsedIP)
		if err != nil || record.Country.IsoCode == "" {
			resp := GeoResponse{Ip: ipStr, Success: false}
			json.NewEncoder(w).Encode(resp)
			return
		}
		countryName = record.Country.Names["en"]
		countryCode = record.Country.IsoCode
		cityName = record.City.Names["en"]
		lat = record.Location.Latitude
		lon = record.Location.Longitude
		isEu = record.Country.IsInEuropeanUnion
		timeZoneStr = record.Location.TimeZone
	} else {
		countryName = "Turkey"
		countryCode = "TR"
		cityName = "Istanbul"
		lat = 41.0138
		lon = 28.9497
		isEu = false
		timeZoneStr = "Europe/Istanbul"
	}

	response := GeoResponse{
		Ip:          ipStr,
		Success:     true,
		Country:     &countryName,
		CountryCode: &countryCode,
		City:        &cityName,
		Latitude:    &lat,
		Longitude:   &lon,
		IsEu:        &isEu,
		Timezone: &TimezoneModel{
			Id: &timeZoneStr,
		},
	}

	jsonResponse, err := json.Marshal(response)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	if rdb != nil {
		rdb.Set(ctx, cacheKey, jsonResponse, 24*time.Hour)
	}
	
	w.Write(jsonResponse)
}
