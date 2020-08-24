export cwt, icwt, wct, wxs

"""

    wxs(ref, cur, t, window, freqbands, dj, unwrapflag)

Compute wavelet cross spectrum for two signals and a given array of frequency bands

# Arguments
- `ref::AbstractArray`: Reference time series
- `cur::AbstractArray`: Current time series
- `t::AbstractArray`: Time vector common to ref and cur
- `window::AbstractArray`: Times over which to compute dv/v
- `fs::Float64`: Sampling frequency
- `freqbands::AbstractArray`: Frequency bands over which to compute dv/v
- `dj::AbstractFloat`: Spacing between discrete scales. Default value is 1/12
- `unwrapflag::Bool`: whether or not to unwrap phase

# Returns
- `freqbands::AbstractArray`: fmin and fmax for each iteration of the dv/v algorithm
- `dvv::Float64`: dv/v for current correlation
- `dvv_err::Float64`: Error for calculation of dv/v
- `int::Float64`: Intercept for regression calculation
- `int_err::Float64`: Error for intercept
- `dvv0::Float64`: dv/v for current correlation forced through the origin
- `dvv0_err::Float64`: Error for calculation of dvv0
"""
function wxs(ref::AbstractArray, cur::AbstractArray, t::AbstractArray, window::AbstractArray, fs::Float64, freqbands::AbstractArray; dj::AbstractFloat=1/12, unwrapflag::Bool=false)
    # define sample interval
    dt = 1/fs

    # perform wavelet coherence transform
    WXS, WXA, WCT, aWCT, coi, freqs = wct(cur, ref, dt, dj, freqbands)

    # do inverse cwt for different frequency bands
    if unwrapflag==true
        phase = unwrap(aWCT, dims=ndims(aWCT))
    else
        phase = aWCT
    end

    # if a frequency window is given (instead of a set of frequency bands), we assume
    # dv/v should be calculated for each frequency. We construct a 2D array of the
    # form [f1 f1; f2 f2; ...], which can be treated the same as a 2D array of frequency bands
    if ndims(freqbands)==1
        freqbands = hcat(freqs, freqs)
    end
    # number of frequency bands
    (nbands,_) = size(freqbands)

    # dt vector will be filled by regression of phase/frequency, and then
    # will be used to find dv/v by regression of dt/t
    delta_t = zeros(nbands, length(window))
    delta_t_err = zeros(nbands, length(window))

    dvv = zeros(nbands)
    dvv_err = similar(dvv)
    int = similar(dvv)
    int_err = similar(dvv)
    dvv0 = similar(dvv)
    dvv0_err = similar(dvv)

    # iterate over frequency bands
    for iband=1:nbands
        (fmin, fmax) = freqbands[iband, :]
        # frequency checks
        if fmax < fmin
            println("Error: please make sure columns 1 and 2 are the correct frequency limits in freqbands!")
        end
        freq_ind = findall(f->(f>=fmin && f<=fmax), freqs)
        iphase = phase[freq_ind, window]

        # get dt by regression of phase delays/frequency band
        for itime=1:length(window)
            if fmin==fmax
                # simple quotient instead of regression, since we have only 1 point
                delta_t[iband, itime] = iphase[itime]/(2π*fmax)
            else
                # get weights
                w = 1 ./ WCT[freq_ind, itime]
                infNaN = findall(x->(isnan.(x) || isinf.(x)), w)
                if length(infNaN)!=0
                    w[infNaN] .= 1.0
                end
                # WLS inversion
                # This does NOT force the best fit line through the origin
                model = glm(@formula(Y ~ X),DataFrame(X=freqs[freq_ind]*2π,Y=iphase[:,itime]),Normal(),IdentityLink(),wts=w)
                delta_t[iband, itime] = coef(model)[2]
                delta_t_err[iband, itime] = stderror(model)[2]
            end
        end

        # regression in time to get time shift
        w2 = 1 ./ mean(WCT[freq_ind, window], dims=1)
        infNaN =findall(x->(isnan.(x) || isinf.(x)), w2[:])
        if length(infNaN)!=0
            w2[:, infNaN] .= 1.0
        end

        # find slope of dt/t to find -dv/v
        dvv[iband], dvv_err[iband], int[iband], int_err[iband], dvv0[iband], dvv0_err[iband] = dvv_lstsq(t[window], delta_t[iband, :], w=w2[:])
    end

    return freqbands, dvv, dvv_err, int, int_err, dvv0, dvv0_err
end

"""

  cwt(signal,dt,freqmin,freqmax)

Continuous wavelet transform of the signal at specified scales.
Note: uses the Morlet wavelet ONLY.

# Arguments
- `signal::AbstractArray`: Input signal array.
- `dt::AbstractFloat`: Sampling interval [s].
- `freqmin::AbstractFloat`: Minimum frequency for cwt [Hz].
- `freqmax::AbstractFloat`: Maximum frequency for cwt [Hz].
- `f0::Real`: Nondimensional frequency from Torrence & Campo, 1998 eq. 1 [Hz].
- `dj::AbstractFloat`: Spacing between discrete scales. Default value is 1/12.

# Returns
- `W::AbstractArray`: Wavelet transform from Morlet wavelet.
- `freqs::AbstractArray`: Fourier frequencies for wavelet scales [Hz].
- `coi::AbstractArray`: Cone of influence - maximum period (in s) of useful
    information at that particular time. Periods greater than
    those are subject to edge effects.

This is a Julia translation of the cwt in pycwt https://github.com/regeirk/pycwt
"""
function cwt(signal::AbstractArray{T,1},dt::AbstractFloat,freqmin::AbstractFloat,
             freqmax::AbstractFloat;f0=6.,dj=1/12) where T <: AbstractFloat
    n0 = length(signal)
    flambda = T.((4 .* π) ./ (f0 .+ sqrt(2 .+ f0^2)))
    s0 = 2 * dt / flambda
    J = convert(Int,round(log2(n0 .* dt ./ s0) ./ dj))

    # The scales as of Mallat 1999
    sj = T.(s0 .* 2 .^ ((0:J) .* dj))
    freqs = 1 ./ (flambda .* sj)

    # subset by freqmin & freqmax
    ind = findall((freqs .>= freqmin) .& (freqs .<= freqmax))
    sj = sj[ind]
    freqs = freqs[ind]

    # signal fft
    signal_ft = fft(signal,1)
    N = length(signal_ft)
    # Fourier angular frequencies
    ftfreqs = T.(2 .* π * FFTW.fftfreq(n0,1/dt))

    # Creates wavelet transform matrix as outer product of scaled transformed
    # wavelets and transformed signal according to the convolution theorem.
    # (i)   Transform scales to column vector for outer product;
    # (ii)  Calculate 2D matrix [s, f] for each scale s and Fourier angular
    #       frequency f;
    # (iii) Calculate wavelet transform;
    psi_ft_bar = ((sj' .* ftfreqs[2] .* T(N)) .^ T(0.5)) .* conj.(psi_ft(ftfreqs * sj',f0))
    W = ifft(signal_ft .* psi_ft_bar,1)

    # Checks for NaN in transform results and removes them from the scales if
    # needed, frequencies and wavelet transform. Trims wavelet transform at
    # length `n0`.
    sel = findall(.!all(isnan.(W),dims=1)[:])
    if length(sel) > 0
        sj = sj[sel]
        freqs = freqs[sel]
        W = W[:,sel]
    end

    # Determines the cone-of-influence. Note that it is returned as a function
    # of time in Fourier periods. Uses triangualr Bartlett window with
    # non-zero end-points.
    coi = n0 ./ 2 .- abs.((0:n0-1) .- (n0 - 1.) ./2.)
    coi = T.(flambda ./ sqrt(2.) .* dt .* coi)
    return W, sj, freqs, coi
end

"""

  icwt(W,sj,dt)

Inverse continuous wavelet transform at specified scales.
Note: uses the Morlet wavelet ONLY.

# Arguments
- `W::AbstractArray`: Wavelet transform, the result of the `cwt` function.
- `sj::AbstractArray`: Scale indices as returned by the `cwt` function.
- `dt::AbstractFloat`: Sampling interval [s].
- `dj::AbstractFloat`: Spacing between discrete scales. Default value is 1/12.

# Returns
- `iW::AbstractArray`: Inverse wavelet transform from Morlet wavelet.

This is a Julia translation of the icwt in pycwt https://github.com/regeirk/pycwt
Note that the pycwt version has incorrect scaling.
"""
function icwt(W::AbstractArray, sj::AbstractArray, dt::AbstractFloat;dj=1/12)
    T = real(eltype(W))
    # As of Torrence and Compo (1998), eq. (11)
    iW = T(dj .* sqrt(dt) ./ 0.776 .* (pi ^ 0.25)) .* sum(real.(W) ./ (sj .^ T(0.5))',dims=2)
    return iW
end

"""

  icwt(W,sj,dt)

Inverse continuous wavelet transform at specified scale.
Note: uses the Morlet wavelet ONLY.

# Arguments
- `W::AbstractArray`: Wavelet transform, the result of the `cwt` function.
- `sj::AbstractFloat`: Scale index as returned by the `cwt` function.
- `dt::AbstractFloat`: Sampling interval [s].
- `dj::AbstractFloat`: Spacing between discrete scales. Default value is 1/12.

# Returns
- `iW::AbstractArray`: Inverse wavelet transform from Morlet wavelet.

This is a Julia translation of the icwt in pycwt https://github.com/regeirk/pycwt
Note that the pycwt version has incorrect scaling.
"""
function icwt(W::AbstractArray, sj::AbstractFloat, dt::AbstractFloat;dj=1/12)
    T = real(eltype(W))
    # As of Torrence and Compo (1998), eq. (11)
    iW = T(dj .* sqrt(dt) ./ 0.776 .* (pi ^ 0.25)) .* real.(W) ./ sj ^ T(0.5)
    return iW
end

function psi_ft(A::AbstractArray{T},f0::Real) where T <: AbstractFloat
    return exp.(T(-0.5) .* (A .- T(f0)) .^2) .* T(π ^ -0.25)
end

"""

    smooth(W, dt, dj, scales)

Smooth wavelet spectrum.

# Arguments
- `W::AbstractArray`: wavelet spectrum
- `dt::Float64`: sampling interval in time
- `dj::Float64`: spacing between discrete scales
- `scales::AbstractArray`: wavelet scales

# Returns
- `T::AbstractArray`: Smoothed wavelet spectrum
"""
function smooth(W::AbstractArray, dt::Float64, dj::Float64, scales::AbstractArray)
    # The smoothing is performed by using a filter given by the absolute value
    # of the wavelet function at each scale, normalized to have a total weight
    # of unity, as per suggestions by Torrence &W ebster (1999) and by Grinsted et al. (2004).
    (m, n) = size(W)

    # Filter in time
    k = 2π*FFTW.fftfreq(length(W[1,:]))
    k2 = k.^2
    snorm = scales ./ dt

    # Smoothing by Gaussian window (absolute value of wavelet function)
    # using the convolution theorem: multiplication by Gaussian curve in
    # Fourier domain for each scale, outer product of scale and frequency
    F = exp.(-0.5 .* (snorm.^2) .* k2') # outer product
    smooth = (ifft(F .* fft(W,2), 2))

    T = smooth[:, 1:n] # Remove possible padded region due to FFTW

    # Filter in scale. For the Morlet wavelet, this is simply a boxcar with 0.6 width
    # construct boxcar
    wsize = convert(Int64, round(0.60 / dj * 2))
    if wsize % 2 == 0
        wsize+=1
    end
    halfWin = div(wsize,2)

    # iterate over 'horizontal' and smooth in the 'vertical'
    # this could also be done by adding an axis to the transpose and performing a 2d convolution
    for i=1:size(T,2)
        # pad signal for 'same' padding
        paddedT = vcat(T[1,i]*ones(halfWin), T[:,i], T[end,i]*ones(halfWin))
        # smooth signal
        win = Array{eltype(paddedT), 1}(undef, wsize)
        win.=ones(wsize)/wsize
        smoothT = conv(paddedT, win)
        # trim signal
        T[:,i] = smoothT[2*halfWin+1:end-2*halfWin]
    end

    return T
end

"""

    wct(y1, y2, dt, dj, freqbands)

Wavelet coherence transform, which finds regions in the wavelet domain where the two time
series co-vary but don't necessarily have high power.

# Arguments
- `y1::AbstractArray`: input signal
- `y2::AbstractArray`: input signal
- `dt::AbstractFloat`: sampling interval in time
- `dj::AbstractFloat`: spacing between discrete scales
- `freqbands::AbstractArray`: Frequency bands over which to compute dv/v
- `f0::Real`: Nondimensional frequency from Torrence & Campo, 1998 eq. 1 [Hz].
- `norm::Bool`: Whether or not to normalize signals before cwt

# Returns
- `WXS::AbstractArray`: Wavelet cross-spectrum
- `WXA::AbstractArray`: Amplitude of wavelet cross-spectrum
- `rWCT::AbstractArray`: Real part of the wavelet coherence transform
- `aWCT::AbstractArray`: Angle of wavelet coherence transform
- `coi::AbstractArray`: Cone of influence - maximum period (in s) of useful
    information at that particular time. Periods greater than
    those are subject to edge effects.
- `freqs::AbstractArray`: Fourier frequencies for wavelet scales [Hz].

Original from pycwt and modified from Python implementation by Congcong Yuan
"""
function wct(y1::AbstractArray, y2::AbstractArray, dt::AbstractFloat, dj::AbstractFloat, freqbands::AbstractArray; f0=6.,norm::Bool=true)
    # normalize signals
    if norm
        y1 = (y1 .- mean(y1)) ./ std(y1)
        y2 = (y2 .- mean(y2)) ./ std(y2)
    end

    # calculate the CWT of the time series, using identical parameters for both calculations
    W1, sj, freqs, coi = cwt(y1, dt, minimum(freqbands), maximum(freqbands))
    W2, sj, freqs, coi = cwt(y2, dt, minimum(freqbands), maximum(freqbands))
    W1=W1'
    W2=W2'

    scales = Array{Float64,2}(undef, size(W1))
    for i=1:size(scales, 2)
        scales[:,i] .= sj
    end

    # smooth wavelet spectra before truncating
    S1 = smooth(abs.(W1).^2 ./ scales, dt, dj, sj)
    S2 = smooth(abs.(W2).^2 ./ scales, dt, dj, sj)

    # compute cross wavelet transform
    W12 = W1 .* conj.(W2)

    S12 = smooth(W12 ./ scales, dt, dj, sj)
    WCT = abs.(S12).^2 ./ (S1 .* S2)
    aWCT = angle.(W12)

    # calculate cross spectrum and its amplitude
    WXS = W12
    WXA = abs.(S12)

    return WXS, WXA, real.(WCT), aWCT, coi, freqs
end
