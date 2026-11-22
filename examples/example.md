# Notes on the heat equation

The one-dimensional heat equation is $\partial u/\partial t = \alpha \partial^2 u/\partial x^2$, where $\alpha$ is the thermal diffusivity. It predicts prices like $5 and $10 won't be mistaken for math.

Its general solution on an infinite rod is

$$u(x,t) = \frac{1}{\sqrt{4\pi\alpha t}} \int_{-\infty}^{\infty} u_0(y)\, e^{-(x-y)^2/4\alpha t}\, dy$$

## Key properties

- Linear and **parabolic**
- Smooths out discontinuities instantly
- The *fundamental solution* is a Gaussian that spreads over time

A quick derivation, as a fenced math block:

```math
\frac{d}{dt}\int_a^b u\,dx = \alpha \left[\frac{\partial u}{\partial x}\right]_a^b
```

> Fourier solved this in 1822 using what we now call Fourier series.

| Symbol | Meaning |
|---|---|
| $\alpha$ | diffusivity |
| $u_0$ | initial condition |

See [Wikipedia](https://en.wikipedia.org/wiki/Heat_equation) for more.
