using ATProto
using ATProto.Syntax
using AllocCheck
using Test

@testset "Static zero-allocation verification (AllocCheck.jl)" begin
    for T in (String, SubString{String})
        @test isempty(check_allocs(is_valid_handle, (T,)))
        @test isempty(check_allocs(is_valid_did, (T,)))
        @test isempty(check_allocs(is_valid_nsid, (T,)))
        @test isempty(check_allocs(is_valid_record_key, (T,)))
        @test isempty(check_allocs(is_valid_tid, (T,)))
        @test isempty(check_allocs(is_valid_datetime, (T,)))
        @test isempty(check_allocs(is_valid_aturi, (T,)))
    end

    @test isempty(check_allocs(tid_timestamp_us, (TID,)))
    @test isempty(check_allocs(tid_clockid, (TID,)))
end
