#=

Ray-traced forest of binary trees
Alejandro Morales Sierra
Centre for Crop Systems Analysis - Wageningen University

In this example we extend the binary forest example to couple growth to light
interception, using a simple light model, where each tree is described by a 
separate graph object and parameters driving the growth of these trees vary 
across individuals following a predefined distribution. This is not intended
an optimal implementation of such a model but rather a demonstration of how to
use the ray tracer within VPL in combination with Sky package to simulate light
distribution within a scene and retrieved the resulting values on an organ basis.

The following packages are needed:
=#
using VPL
using Base.Threads: @threads
using Plots
import Random
using Sky
using FastGaussQuadrature

#=
The data types needed to simulate the binary trees are given in the following
module. The main difference with respect to the previous example is that more
information is being stored in the Internode object, including the optical
properties as well as biomass. The `treeparams` object stores the total PAR
absorbed each day, the total biomass of the tree, the specific internode weight
and the radiation use efficiency (RUE).
=#
module rbtree
    using VPL
    # Meristem
    struct Meristem <: VPL.Node end
    # Node
    struct Node <: VPL.Node end
    # Internode
    mutable struct Internode <: VPL.Node
        biomass::Float64
        length::Float64
        width::Float64
        material::Lambertian{3} # Optical properties for 3 wavebands
    end
    # Tree-level variables
    mutable struct treeparams
        PAR::Float64     # Total PAR intercepted by the tree in a day
        RUE::Float64     # Convert absorbed PAR to biomass growth
        SIW::Float64     # Specific internode weight
        Biomass::Float64 # Current total biomass
    end
end

#=
The methods for creating the geometry and color of the tree are the same as in
the previous example with the addition that we also assign a `Material` object
to the argument `material` (which is a `Lambertian` object in this case).
=#

function VPL.feed!(turtle::Turtle, i::rbtree.Internode, vars)
    HollowCube!(turtle, length = i.length, height =  i.width, width =  i.width, 
                move = true, color = RGB(0,0.35,0), material = i.material)
    return nothing
end

#=
The growth rule is also the same as in the previous example, but now the Internode
takes initial biomass and optical properties. The optical properties are stored
in a `Lambertian` object, which is a `Material` object that defines the transmittance
and reflectance of the material for each waveband to be simulated (in this case three).
=#
# Create a new material object with the optical properties
mat() = Lambertian(τ = (0.0, 0.0, 0.0), # transmittance for blue, green, red
                   ρ = (0.05, 0.2, 0.1)) # reflectance for blue, green, red

# Create right side of the growth rule (parameterized by initial values of the organ)
function create_branching_rule(biomass, length, width)
    mer -> begin
        # New branches
        branch1 = RU(-60.0) + rbtree.Internode(biomass, length, width, mat()) + RH(90.0) + rbtree.Meristem()
        branch2 = RU(60.0)  + rbtree.Internode(biomass, length, width, mat()) + RH(90.0) + rbtree.Meristem()
        # Sub-graph to be added to the tree
        rbtree.Node() + (branch1, branch2)
    end
end

# The creation of each individual tree also resembles the previous example

# Create a tree given the origin and RUE
function create_tree(origin, RUE)
    SIW    = 1e6 # g/m3 (typical wood density for a hardwood)
    length = 0.5 # m
    width  = 0.05 # m
    biomass = length*width^2*SIW # g
    # Growth rule
    rule = Rule(rbtree.Meristem, rhs = create_branching_rule(biomass, length, width))
    axiom = T(origin) + rbtree.Internode(biomass, length, width, mat()) + rbtree.Meristem()
    tree = Graph(axiom = axiom, rules = Tuple(rule), 
                 vars = rbtree.treeparams(0.0, RUE, SIW, biomass))
    return tree
end

# We can now create a forest of trees on a regular grid with random RUE values:
# Regular grid of trees 2 meters apart
origins = [Vec(i,j,0) for i = 1:2.0:20.0, j = 1:2.0:20.0];
Random.seed!(123456789)

# Assume RUE follows a log-normal distribution wth low standard deviation
RUE_distr(n) = exp.(randn(n)) .+ 15.0 # Unrealistic value to speed up simulation! 
RUEs = RUE_distr(length(origins))
histogram(RUEs)

# Create the forest
forest = [create_tree(origins[i], RUEs[i]) for i in 1:100];

#=
As growth is now dependent on intercepted PAR via RUE, we now need to simulate
light interception by the trees. We will use a ray-tracing approach to do so.
The first step is to create a scene with the trees and the light sources. As for
rendering, the scene can be created from the `forest` object by simply calling 
`Scene(forest)` that will generate the 3D meshes and connect them to their 
optical properties.

However, we also want to add a soil surface as this will affect the light 
distribution within the scene due to reflection from the soil surface. This is
similar to the customized scene that we created in the previous example. Note
that the `soil_material` created below is stored in the scene but nowhere else.
If we wanted to recover the irradiance absorbed by the soil tile later on, we 
would need to store this information somewhere else.
=#
function create_soil()
    soil = Rectangle(length = 21.0, width = 21.0)
    rotatey!(soil, π/2) # To put it in the XY plane
    VPL.translate!(soil, Vec(0.0, 10.5, 0.0)) # Corner at (0,0,0)
    return soil
end
function create_scene(forest)
    # These are the trees
    scene = Scene(forest)
    # Add a soil surface
    soil = create_soil()
    soil_material = Lambertian(τ = (0.0, 0.0, 0.0),
                               ρ = (0.21, 0.21, 0.21))
    add!(scene, mesh = soil, material = soil_material)
    # Return the scene
    return scene
end

#=
Given the scene, we can create the light sources that can approximate the solar
irradiance on a given day, location and time of the day using the functions from
the Sky package (see package documentation for details). Given the latitude,
day of year and fraction of the day (`f = 0` being sunrise and `f = 1` being sunset),
the function `clear_sky()` computes the direct and diffuse solar radiation assuming
a clear sky. These values may be converted to different wavebands and units using
`waveband_conversion()`. Finally, the collection of light sources approximating
the solar irradiance distribution over the sky hemisphere is constructed with the
function `sky()` (this last step requires the 3D scene as input in order to place
the light sources adequately).
=#
function create_sky(;scene, f, lat = 52.0*π/180.0, DOY = 182)
    # Compute solar irradiance
    Ig, Idir, Idif = clear_sky(lat = lat, DOY = DOY, f = f) # W/m2
    # Conversion factors to red, green and blue for direct and diffuse irradiance
    wavebands = (:blue, :green, :red)
    f_dir = Tuple(waveband_conversion(Itype = :direct,  waveband = x, mode = :power) for x in wavebands)
    f_dif = Tuple(waveband_conversion(Itype = :diffuse, waveband = x, mode = :power) for x in wavebands)
    # Actual irradiance per waveband
    Idir_color = Tuple(f_dir[i]*Idir for i in 1:3)
    Idif_color = Tuple(f_dif[i]*Idif for i in 1:3)
    # Create the light sources and assign number of rays
    sources = sky(scene, 
                  Idir = Idir_color, # Direct solar radiation from above
                  nrays_dir = 1_000_000, # Number of rays for direct solar radiation
                  Idif = Idif_color, # Diffuse solar radiation from above
                  nrays_dif = 1_000_000, # Total number of rays for diffuse solar radiation
                  sky_model = StandardSky, # Angular distribution of solar radiation
                  dome_method = equal_solid_angles, # Discretization of the sky dome
                  ntheta = 9, # Number of discretization steps in the zenith angle 
                  nphi = 12) # Number of discretization steps in the azimuth angle
    return sources
end

#=
The 3D scene and the light sources are then combined into a `RayTracer` object,
together with general settings for the ray tracing simulation chosen via `RTSettings()`.
The most important settings refer to the Russian roulette system and the grid 
cloner (see section on Ray Tracing for details). The settings for the Russian
roulette system include the number of times a ray will be traced
deterministically (`maxiter`) and the probability that a ray that exceeds `maxiter`
is terminated (`pkill`). The grid cloner is used to approximate an infinite canopy
by replicating the scene in the different directions (`nx` and `ny` being the
number of replicates in each direction along the x and y axes, respectively). It
is also possible to turn on parallelization of the ray tracing simulation by
setting `parallel = true` (currently this uses Julia's builtin multithreading
capabilities). 

In addition `RTSettings()`, an acceleration structure and a splitting rule can
be defined when creating the `RayTracer` object (see ray tracing documentation 
for details). The acceleration structure allows speeding up the ray tracing
by avoiding testing all rays against all objects in the scene.
=#
function create_raytracer(scene, sources)
    settings = RTSettings(pkill = 0.9, maxiter = 4, nx = 5, ny = 5, parallel = true)
    RayTracer(scene, sources, settings = settings, acceleration = BVH,
                     rule = SAH{6}(5, 10));
end

#=
The actual ray tracing simulation is performed by calling the `trace!()` method
on the ray tracing object. This will trace all rays from all light sources and
update the radiant power absorbed by the different surfaces in the scene inside
the `Material` objects (see `feedmaterial!()` above):
=#
function run_raytracer!(forest; f = 0.5, DOY = 182)
    scene   = create_scene(forest)
    sources = create_sky(scene = scene, f = f, DOY = DOY)
    rtobj   = create_raytracer(scene, sources)
    trace!(rtobj)
    return nothing
end

#=
The total PAR absorbed for each tree is calculated from the material objects of
the different internodes (using `power()` on the `Material` object). Note that
the `power()` function returns three different values, one for each waveband,
but they are added together as RUE is defined for total PAR.

In most cases the relationship between absorbed PAR and growth is not linear and
thus the process needs to be integrated over the day. That is not case here since
we use an RUE constant, however the general scenario is shown for generality. For
more complex models (e.g., where photosynthesis is computed for each organ) the
`calculate_PAR!` function below would be replaced by a function that computes
photosynthesis for each organ and then adds up to the tree level.
=#

getInternode = Query(rbtree.Internode)

# Run the ray tracer, calculate PAR absorbed per tree and add it to the daily
# total using general weighted quadrature formula
function calculate_PAR!(forest; f = 0.5, w = 1.0, dt = 1.0, DOY = 182)
    # Run the ray tracer
    run_raytracer!(forest, f = f, DOY = DOY)
    # Add up PAR absorbed by each tree and add to the tree variables
    @threads for tree in forest
        PAR = 0.0
        for i in apply(tree, getInternode)
            PAR += sum(power(i.material))
        end
        tree.vars.PAR += w*PAR*dt
    end
    return nothing
end

# Gaussian-Legendre integration of PAR absorbed over the day
function daily_PAR!(forest; nsteps = 5, DOY = 182, lat = 52.0*π/180.0)
    # Compute length of the day
    dec = declination(DOY)
    dl = day_length(lat, dec)
    dt = dl # Gaussian integration generates a weighted average, so this is total daylength
    # Generate nodes and weights for Gaussian-Legendre integration
    nodes, weights = gausslegendre(nsteps)
    ws   = weights./2 # Scale weights to add up to 1
    fs   = 0.5 .+ nodes./2 # Scale nodes to [0,1]
    # Integrate over the day
    for i in 1:nsteps
        calculate_PAR!(forest, f = fs[i], w = ws[i], dt = dt, DOY = DOY)
    end
    return nothing
end

# Reset PAR absorbed by the tree (at the start of a new day)
function reset_PAR!(forest)
    for tree in forest
        tree.vars.PAR = 0.0
    end
    return nothing
end

#=
Given the total daily PAR absorbed by each tree, it may be converted to biomass
using the RUE. The growth function below is called at the end of each day and
updates the dimensions of each internode inside a tree based on the new biomass,
as well as add new organs to the tree by applying the graph rewriting rule.
=#

# Growth function
function growth!(tree)
    # Total growth based on RUE
    growth = tree.vars.RUE*tree.vars.PAR/1e6
    # Allocate growth to each organ and compute new dimensions
    for i in apply(tree, getInternode)
        biomass    = i.length*i.width^2*tree.vars.SIW
        i.biomass += growth*i.biomass/tree.vars.Biomass # Simple allocation rule
        volume     = i.biomass/tree.vars.SIW
        i.length   = cbrt(100volume) # Assume width = length/10
        i.width    = i.length/10
    end
    # Update total tree biomass
    tree.vars.Biomass += growth
    # Create new organs with the growth rule
    rewrite!(tree)
end

#=
Finally, all the pieces may be combined into a single function that simulates
the daily steps of the model:
=#
function daily_step!(forest, DOY)
    # Reset PAR absorbed by the tree
    reset_PAR!(forest)
    # Integrate PAR absorbed over the day
    daily_PAR!(forest, DOY = DOY)
    # Update tree dimensions and add new organs
    @threads for tree in forest
        growth!(tree)
    end
end

# We can create a function for rendering the forest in combination with the soil:
function render_forest(forest)
    # Plot the forest
    display(render(forest, axes = false))
    # Generate the soil and add it
    soil = create_soil()
    render!(soil, color = RGB(1.0,1.0,0.5))
end

#=
We can now simulate and visualize the growth of the forest by calling the 
`daily_step!` function iteratively:  
=#
newforest = deepcopy(forest)
start = 182
render_forest(forest)
for i in 1:3
    println("Day $i")
    daily_step!(newforest, start + i)
    render_forest(newforest)
end


