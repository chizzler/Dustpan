/// Where Week and Day's grid was scrolled to, kept by the calendar window while Month shows.
/// A plain class, not observed: the grid writes it on every scroll without redrawing anything.
final class ScrollMemory {
    var y: Double?
}
