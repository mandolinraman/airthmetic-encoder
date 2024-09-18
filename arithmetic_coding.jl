struct Endec
    ell::Int
    delta::Int
    index_of::Dict{Char,Tuple{Int,Int,Int}}
    symbol::Vector{Tuple{Char,Int,Int}}
end

function divmod_abc(a, b, c)
    """
    Given three unsigned integers a, b, c such that a, b and 2*c - 1 fit in
    L-bit registers, compute:

        q = (a * b) // c and r = (a * b) % c

    without overflowing using only L-bit registers for all arithmetic.
    """

    # It's slightly more efficient if b < a
    if a < b
        return divmod_abc(b, a, c)
    end

    # Let k > 1 be an integer such that k * c - 1 doesn't overflow. We
    # choose k = 2 which requires that 2 * c - 1 is an L-bit value
    k = 2
    qm, rm = divrem(a, c)
    q, r = 0, 0
    m = b

    # We want to maintain the invariant:
    #     a * b / c = (q + r / c) + (qm + rm / c) * m
    #     where 0 <= r, rm < c
    while m > 0
        # Let m = k * t + s with 0 <= s < k:
        (t, s) = divrem(m, k)

        # Then,
        #     a * b = (q + r/C) + (qm + rm / c) * (k * t + s)
        #     = (q + qm * s) + (r + rm * s) / c + (qm * k + rm * k / c) * t
        if s > 0
            r += rm * s  # won't overflow since r + rm * s < c * k
            q += qm * s + r ÷ c  # won't overflow because q <= q_final
            r = r % c
        end

        # At this point q and r have been modified so that we now have
        # a * b / c = (q + r / c) + (qm * k + rm * k / c) * t
        if t > 0
            # simplify the second term
            rm *= k  # won't overflow since rm * k < c * k
            qm = k * qm + rm ÷ c  # won't overflow because qm * t <= q_final
            rm = rm % c  # won't overflow
        end

        m = t

        # At this point qm, rm and m have been modified so that
        # we maintain the invariant:
        #   a * b / c = (q + r / c) + (qm + rm / c) * m
        #
        # and m is now strictly smaller.
    end

    # # debug
    # @assert (q, r) == divrem(a * b,  c)

    return (q, r)
end

function get_frequencies(text::String)
    freqs = Dict{Char,Int}()
    for c in text
        freqs[c] = get(freqs, c, 0) + 1
    end

    return freqs
end

function make_endec(freqs, register_size=16, pad=0)
    index_of = Dict{Char,Tuple{Int,Int,Int}}()
    symbol = Tuple{Char,Int,Int}[]
    cmf = 0
    for (index, (sym, prob)) in enumerate(freqs)
        # println("$index -> $sym -> $prob")
        index_of[sym] = (index, prob, cmf)
        push!(symbol, (sym, prob, cmf))
        cmf += prob
    end

    @assert cmf <= (1 << (register_size - 1))

    return Endec(register_size, pad, index_of, symbol)
end

function encode(endec::Endec, message::String)
    "Encode a message."

    # local helper function
    function bit_plus_inversions(bit)
        append!(code_output, bit, fill(1 - bit, num_inversions))
        num_inversions = 0
    end

    num = length(endec.symbol)
    sum_freq = sum(s[2] for s in endec.symbol)

    code_output = Int[]
    num_inversions = 0

    half = 1 << (endec.ell - 1)
    quarter = 1 << (endec.ell - 2)
    three_quarters = half + quarter

    # low and hight are always L-bit values
    low = 0
    high = 2 * half - 1

    for (j, sym) in enumerate(message)
        span = high - low + 1 - num * endec.delta  # could become (L+1) bit value
        index, prob, cmf = endec.index_of[sym]  # extract index, probability and cmf
        high = low + divmod_abc(span, cmf + prob, sum_freq)[1] + (index + 1) * endec.delta - 1
        low = low + divmod_abc(span, cmf, sum_freq)[1] + index * endec.delta

        while true
            if high < half
                bit_plus_inversions(0)
            elseif low >= half
                low -= half
                high -= half
                bit_plus_inversions(1)
            elseif low >= quarter && high < three_quarters
                low -= quarter
                high -= quarter
                num_inversions += 1
            else
                break
            end

            # double the interval size
            low = 2 * low
            high = 2 * high + 1
        end
    end

    # At this point we have either
    #   low < quarter < half <= high        => contains [quarter, half]
    #   low < half < three_quarters <= high => contains [half, three_quarters]

    # # According to the paper we output two more bits to specify which of the two
    # # quarter width intervals would be contained in our final interval:
    # num_inversions += 1
    # if low < quarter:
    #     endec.bit_plus_inversions(0)
    # else:
    #     endec.bit_plus_inversions(1)

    # But we can output only one more bit "1" to select the point at "half"
    # which is always contained in the final interval:
    bit_plus_inversions(1)

    return code_output
end

function decode(endec::Endec, codeword::Vector{Int}, mlen::Int)
    """Decode a message."""

    num = length(endec.symbol)
    sum_freq = sum(s[2] for s in endec.symbol)

    message_output = Char[]

    half = 1 << (endec.ell - 1)
    quarter = 1 << (endec.ell - 2)
    three_quarters = half + quarter

    low = 0
    high = 2 * half - 1

    value = 0  # currrent register contents
    j = 1
    for _ in 1:endec.ell
        value = 2 * value + (j <= length(codeword) ? codeword[j] : 0)
        j += 1
    end

    for _ in 1:mlen
        # decode next symbol
        span = high - low + 1 - num * endec.delta  # could become (L+1) bit value

        # Our goal is to find the largest symbol index i such that
        #     value - low >= floor(span * cmf[i] / sum_freq)
        # <=> value - low + 1 - i * delta > span * cmf[i] / sum_freq
        # <=> cmf[i] < (value - low + 1 - i * delta) * sum_freq / span
        # <=> cmf[i] < ceil((value - low + 1 - i * delta) * sum_freq / span)
        #
        # We'll precompute d * sum_freq / span (where d = value - low + 1)
        # and delta * sum_freq / span (when delta != 0). Then we can efficiently
        # compute the RHS above as we increment i

        d = value - low + 1  # could become (L+1) bit value
        q, r = divmod_abc(d, sum_freq, span)
        # Let's convert this fraction into a representation of the form:
        #     (q - r / span) where 0 <= r < span
        # so that q = ceil(d * sum_freq / span)
        if r != 0
            q += 1
            r = span - r
        end

        qi, ri = (endec.delta == 0 ? (0, 0) : divmod_abc(sum_freq, endec.delta, span))
        index = 0
        for (i, (_, _, cmf)) in enumerate(endec.symbol)
            # print(endec.symbol[i], q)
            if cmf < q
                index = i # i could be the next symbol
            else
                break
            end

            if endec.delta != 0
                # update (q, r) -> (q - qi, r + ri) for next iteration
                r += ri
                q = q - qi - r ÷ span
                r = r % span
            end
        end

        sym, prob, cmf = endec.symbol[index]  # extract symbol, probability and cmf
        high = low + divmod_abc(span, cmf + prob, sum_freq)[1] + index * endec.delta - 1
        low += divmod_abc(span, cmf, sum_freq)[1] + (index - 1) * endec.delta

        # print(f"Decoded: symbol[{j}] = {sym}")
        # print(f"       => [{low/full}, {(high+1)/full})")

        append!(message_output, sym)
        while true
            if high < half
                # do nothing
            elseif low >= half
                value -= half
                low -= half
                high -= half
            elseif low >= quarter && high < three_quarters
                value -= quarter
                low -= quarter
                high -= quarter
                # print(f" Shifted: [{low/full}, {(high+1)/full}) | codeval = {value/full}")
            else
                break
            end

            low = 2 * low
            high = 2 * high + 1
            value = 2 * value + (j <= length(codeword) ? codeword[j] : 0)  # default to 0
            j += 1
            # print(f"Expanded: [{low/full}, {(high+1)/full}) | codeval = {value/full}")
        end
        # print()
    end
    return join(message_output)
end

function test(message, frequencies=nothing)
    if frequencies == nothing
        frequencies = get_frequencies(message)
    end
    endec = make_endec(frequencies)
    encoded = encode(endec, message)
    decoded = decode(endec, encoded, length(message))

    # encode and decode message
    encoded_string = join(encoded)
    entropy = length(message) * log2(sum(values(frequencies))) - sum(log2(frequencies[c]) for c in message)
    entropy = round(entropy, digits=2)

    # print info
    println("Entropy of msg = $(entropy) bits")
    println("Encoded length = $(length(encoded)) bits")

    maxlen = 128
    if length(encoded) < maxlen
        println("Message string = \"$message\"")
    else
        println("Message string = \"$(message[1:maxlen])...\"")
    end

    if length(encoded_string) < maxlen
        println("Encoded string = $encoded_string")
    else
        println("Encoded string = $(encoded_string[1:maxlen])...")
    end

    if length(decoded) < maxlen
        print("Decoded string = \"$decoded\"")
    else
        print("Decoded string = \"$(decoded[1:maxlen])...\"")
    end

    @assert message == decoded
end

# test 1
println("\nTest 1\n======")
message = "ABBY CADABBY"
frequencies = Dict('A' => 126, 'B' => 167, 'C' => 116, 'D' => 88, 'Y' => 89, ' ' => 100)
test(message, frequencies)

# test 2
println("\nTest 2\n======")
message = read("arithmetic_coding.jl", String)
test(message)
