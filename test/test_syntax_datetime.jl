using Test
using ATProto
using ATProto.Syntax
using Dates

@testset "Datetime" begin
    @testset "valid" begin
        for s in (
            "2023-01-01T00:00:00Z",
            "1985-04-12T23:20:50Z",
            "1985-04-12T23:20:50.52Z",
            "1985-04-12T23:20:50.123456789Z",
            "2024-02-29T12:00:00Z",        # leap day in a leap year
            "2023-01-01T00:00:00+00:00",
            "2023-01-01T00:00:00.999+00:00",
            "2023-01-01T00:00:00-08:00",
            "0000-01-01T00:00:00Z",
            "9999-12-31T23:59:59Z",
        )
            @test is_valid_datetime(s)
            @test ensure_datetime_string(s) == s
        end
    end

    @testset "invalid" begin
        for s in (
            "2023-01-01T00:00:00",          # missing timezone
            "2023-01-01 00:00:00Z",         # space separator
            "2023-13-01T00:00:00Z",         # month 13
            "2023-00-01T00:00:00Z",         # month 0
            "2023-02-30T00:00:00Z",         # invalid calendar date
            "2023-02-29T00:00:00Z",         # 2023 is not a leap year
            "2023-01-01T24:00:00Z",         # hour 24
            "2023-01-01T23:59:60Z",         # leap second
            "2023-01-01T23:59:59-00:00",    # -00:00 is rejected
            "2023-1-01T00:00:00Z",          # non-padded month
            "2023-01-01t00:00:00Z",         # lower-case 't'
            "2023-01-01T00:00:00z",         # lower-case 'z'
            "2023-01-01T00:00:00.Z",        # bare '.'
            "2023-01-01T00:00:00+24:00",    # offset hour > 23
            "2023-01-01T00:00:00+05:60",    # offset minute > 59
            "20230101T000000Z",
            "",
        )
            @test !is_valid_datetime(s)
            @test_throws InvalidDatetimeError ensure_datetime_string(s)
        end
        @test_throws InvalidDatetimeError ensure_datetime_string("a"^65)
    end

    @testset "parse" begin
        @test parse_datetime("2023-01-01T00:00:00Z") == DateTime(2023, 1, 1)
        @test parse_datetime("2023-01-01T00:00:00.123Z") ==
              DateTime(2023, 1, 1, 0, 0, 0, 123)
        @test parse_datetime("2023-01-01T12:00:00-08:00") == DateTime(2023, 1, 1, 20, 0, 0)
        @test parse_datetime("2023-01-01T12:00:00+02:00") == DateTime(2023, 1, 1, 10, 0, 0)
        @test_throws InvalidDatetimeError parse_datetime("2023-01-01T00:00:00")
    end

    @testset "serialize" begin
        @test datetime_string(DateTime(2023, 1, 2, 3, 4, 5, 678)) == "2023-01-02T03:04:05.678Z"
        @test datetime_string(DateTime(2023, 1, 2)) == "2023-01-02T00:00:00.000Z"
        @test datetime_string(DateTime(0, 1, 1)) == "0000-01-01T00:00:00.000Z"
        @test_throws InvalidDatetimeError datetime_string(DateTime(10000))
    end

    @testset "normalize" begin
        @test normalize_datetime("2023-01-01T00:00:00Z") == "2023-01-01T00:00:00.000Z"
        @test normalize_datetime("2023-01-01T00:00:00") == "2023-01-01T00:00:00.000Z"  # assumes UTC
        @test normalize_datetime("2023-01-01T12:00:00-08:00") == "2023-01-01T20:00:00.000Z"
        @test_throws InvalidDatetimeError normalize_datetime("not a datetime")
    end
end
